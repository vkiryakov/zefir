//! `odm.Registry`: the connections of a service and their tenants. A
//! connection is a server and a login, one client of the driver with its
//! pool; it lives in generations, and a replacement opens a new one while
//! the old one drains.
//!
//! ```zig
//! var registry = odm.Registry.init(gpa, io, driver.driver(), .{});
//! defer registry.deinit(io);
//! try registry.registerConnection(io, "shared-1", .{ .uri = uri, .password = password });
//! try registry.connect(io, ctx, "shared-1");
//! ```
//!
//! `registerConnection` opens a client without the network; `connect`
//! makes the first connection and checks the login, under the deadline of
//! `ctx`. One operation at a time works on a connection — `connect`,
//! `replaceConnection`, `removeConnection` — and the next one waits for
//! it, within the deadline of its context, or until its task is canceled.
//! A failed connect keeps the client: `connectionStats(io, id).last_failure`
//! holds the driver's text, the log a warning, and `connect` may come
//! again.
//!
//! `replaceConnection` opens a new generation with new settings, connects
//! it and publishes it at once; then it waits, in the caller's task, until
//! the leases of the old one come back, for `Options.drain_timeout` at the
//! most, and closes it. The same settings again do nothing. Leases left
//! after the drain get `Closed`, and their memory stays until they are
//! given back. `removeConnection` drains and closes the same way.
//!
//! `shutdown(io, deadline)` stops the registry: new calls get
//! `ShuttingDown`, every generation drains until the deadline and closes,
//! and leases left then make it `ShutdownTimeout`. `deinit(io)` frees the
//! memory, after a shutdown by now if none came before.
//!
//! The registry has no tasks of its own. It keeps one `std.Io.Mutex` for
//! short work on memory, and never holds it across a call of the driver, a
//! wait or a log line. Every call comes on the `io` of `init`, and the
//! registry stays where it is from its first `registerConnection` on: in
//! safe builds, a call on another `std.Io` or on a moved copy panics.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const errors = @import("errors.zig");
const driver_ = @import("driver.zig");
const fingerprint = @import("fingerprint.zig");
const names = @import("registry/names.zig");
const connection = @import("registry/connection.zig");
const generation = @import("registry/generation.zig");
const Connection = connection.Connection;
const ConnectionState = connection.ConnectionState;
const Failure = connection.Failure;
const Warning = connection.Warning;
const Generation = generation.Generation;
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const Driver = driver_.Driver;
const Client = driver_.Client;
const ConnectionConfig = driver_.ConnectionConfig;
const List = std.DoublyLinkedList;

const Registry = @This();

gpa: Allocator,
/// The `io` of `init`: every call comes on it.
io: Io,
driver: Driver,
options: Options,
/// Guards the lists, the records of connections, the generations and
/// `state`, for short work on memory only.
mutex: Io.Mutex = .init,
/// Wakes the calls that wait for their turn on a connection.
cond: Io.Condition = .init,
/// The ObjectIds of the documents that odm inserts.
ids: bson.ObjectId.Generator,
/// Of the fingerprints of settings.
key: fingerprint.Key,
/// The connections that ids find.
connections: List = .{},
/// The connections that `removeConnection` took out of `connections` and
/// drains.
removing: usize = 0,
/// Every generation until it is freed.
generations: List = .{},
/// The generations closed by force since `init`.
forced: usize = 0,
state: State = .running,
/// The result of the shutdown, for a second call; set once `shut` is.
shutdown_result: errors.ShutdownError!void = {},
/// Set once the shutdown is done.
shut: Io.Event = .unset,
/// The operations of collections and their errors (`stats`).
operations: std.atomic.Value(u64) = .init(0),
operation_errors: std.atomic.Value(u64) = .init(0),
/// Where the first `registerConnection` found the registry, 0 before, in
/// safe builds: a call on a copy somewhere else panics. Atomic: any task
/// may call while another registers.
home: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},

const State = enum { running, stopping, stopped };

pub const Options = struct {
    /// How long `replaceConnection` and `removeConnection` wait for the
    /// leases of an old generation before they close it by force.
    drain_timeout: Io.Duration = .fromSeconds(30),
};

/// A snapshot of the registry, under its lock. The names follow the
/// metrics of the specification; there is no exporter.
pub const Stats = struct {
    connections: Connections,
    /// Old generations whose leases are not back yet: draining, or closed
    /// by force with holders left (odm_connections_draining).
    draining: usize,
    /// The generations closed by force since `init`: their drain ran out,
    /// or the shutdown's deadline came, with leases left.
    forced: usize,
    /// The leases out: sessions, cursors, and the calls of `connect`,
    /// `ping` and `connectionStats` in progress
    /// (odm_connection_leases_active).
    leases: usize,
    tenants: usize,
    /// The operations of collections, queries and `runCommand`, and those
    /// of them that failed.
    operations: u64,
    operation_errors: u64,

    /// The connections in each state.
    pub const Connections = struct { registered: usize, connecting: usize, active: usize, failed: usize, removing: usize };
};

/// A snapshot of one connection.
pub const ConnectionStats = struct {
    state: ConnectionState,
    /// The number of the current generation: 1 for a connection just
    /// registered, one more after each replacement.
    generation: u64,
    /// The leases of its generations, current and old, but this call's.
    leases: usize,
    /// Its old generations whose leases are not back yet.
    draining: usize,
    tenants: usize,
    /// The pool of the driver, when the driver keeps one.
    pool: ?Client.PoolStats,
    /// The error of the latest failed connect or replacement, with the
    /// driver's text. It stays after a later success.
    last_failure: ?Failure,
};

/// A registry without connections, and without the network or tasks: from
/// `io` it takes random bytes for the ObjectIds and for the key of the
/// fingerprints. `gpa` must be thread-safe: the calls of every task take
/// their memory from it. The registry may move until its first
/// `registerConnection`.
pub fn init(gpa: Allocator, io: Io, driver: Driver, options: Options) Registry {
    return .{
        .gpa = gpa,
        .io = io,
        .driver = driver,
        .options = options,
        .ids = .init(io),
        .key = fingerprint.newKey(io),
    };
}

/// Frees the memory, after a `shutdown` by now when none came before. No
/// call may be in progress, and every session and cursor must be deinit
/// first.
pub fn deinit(r: *Registry, io: Io) void {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    const state = r.state;
    r.mutex.unlock(io);
    switch (state) {
        .running => r.shutdown(io, .now(io, .awake)) catch {},
        .stopping => r.shut.waitUncancelable(io),
        .stopped => {},
    }
    // Every generation is closed. One still in the list holds leases, a
    // mistake of the program: its memory stays, a leak rather than a use
    // after free.
    while (r.connections.popFirst()) |node| Connection.of(node).destroy(r.gpa);
    r.* = undefined;
}

/// Stops the registry by `deadline`, the bean contract of `zefir.App`. From
/// now on `registerConnection`, `connect`, `replaceConnection`,
/// `removeConnection`, `ping`, `connectionStats` and the calls waiting for
/// their turn get `ShuttingDown`. Generations that never connected close
/// at once, and a connect in one of them gets `ShuttingDown`; the others
/// drain one after the other, all until the deadline, and close. When
/// leases are left at the deadline, their generations are closed by
/// force, their holders get `Closed`, the log a warning, and the result is
/// `error.ShutdownTimeout`: tasks that held them are still alive. A second
/// call waits for the first and returns its result. The task's
/// cancelation waits until it returns.
pub fn shutdown(r: *Registry, io: Io, deadline: Io.Clock.Timestamp) errors.ShutdownError!void {
    r.checkUse(io);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const until = deadline.toClock(io, .awake).raw;
    r.mutex.lockUncancelable(io);
    switch (r.state) {
        .running => {},
        .stopping => {
            r.mutex.unlock(io);
            r.shut.waitUncancelable(io);
            return r.shutdown_result;
        },
        .stopped => {
            const result = r.shutdown_result;
            r.mutex.unlock(io);
            return result;
        },
    }
    r.state = .stopping;
    // The calls that wait for their turn look again, and stop.
    r.cond.broadcast(io);
    var pending: List = .{};
    var live: List = .{};
    // Closed by force before, with holders left: their leases count too.
    var closed: List = .{};
    var it = r.generations.first;
    while (it) |node| : (it = node.next) {
        const g = Generation.of(node);
        switch (g.state) {
            .pending => {
                generation.beginRetire(io, g, .pending);
                pending.append(&g.shutdown_node);
            },
            .active, .draining => {
                generation.beginRetire(io, g, .live);
                live.append(&g.shutdown_node);
            },
            .closed => {
                g.pins += 1;
                closed.append(&g.shutdown_node);
            },
        }
    }
    r.mutex.unlock(io);

    const now = Io.Clock.awake.now(io);
    while (pending.popFirst()) |node| _ = generation.finishRetire(r, io, Generation.ofShutdown(node), now, .pending);
    var left: usize = 0;
    while (live.popFirst()) |node| {
        if (generation.finishRetire(r, io, Generation.ofShutdown(node), until, .live).forced) |n| left += n;
    }

    var dead: List = .{};
    r.mutex.lockUncancelable(io);
    while (leasesOf(&closed) > 0 and Io.Clock.awake.now(io).nanoseconds < until.nanoseconds) {
        // Each lease given back wakes the wait while the registry stops.
        r.cond.waitTimeout(io, &r.mutex, step(io, .at(until))) catch {};
    }
    left += leasesOf(&closed);
    while (closed.popFirst()) |node| {
        const g = Generation.ofShutdown(node);
        g.pins -= 1;
        if (generation.settle(r, g)) dead.append(&g.shutdown_node);
    }
    r.state = .stopped;
    r.shutdown_result = if (left > 0) error.ShutdownTimeout else {};
    const result = r.shutdown_result;
    r.shut.set(io);
    r.mutex.unlock(io);
    while (dead.popFirst()) |node| generation.destroy(r, Generation.ofShutdown(node));
    if (left > 0) Warning.log(.{ .shutdown_forced = .{ .leases = left } });
    return result;
}

fn leasesOf(list: *const List) usize {
    var n: usize = 0;
    var it = list.first;
    while (it) |node| : (it = node.next) n += Generation.ofShutdown(node).leases;
    return n;
}

/// Takes a connection under `id`, without the network: checks the id
/// (1–64 bytes of A–Z a–z 0–9 _ - . :), opens a client of the driver with
/// `config` and keeps the fingerprint of the settings, never the password.
/// `config.diagnostics` says why it failed. `ConnectionExists` when the id
/// is taken; of several calls for one new id at once, one registers it.
pub fn registerConnection(r: *Registry, io: Io, id: []const u8, config: ConnectionConfig) Error!void {
    r.checkUse(io);
    const d = config.diagnostics;
    if (d) |x| x.* = .{};
    if (names.connectionId(id)) |problem| return fail(d, error.InvalidArgument, "odm: {s}", .{problem});
    // A known id needs no client.
    r.mutex.lockUncancelable(io);
    const known = r.refusal(id);
    r.mutex.unlock(io);
    if (known) |err| return refuse(d, err, id);

    const print = fingerprint.of(&r.key, config.uri, config.password);
    const c = try Connection.create(r.gpa, id, print);
    errdefer c.destroy(r.gpa);
    const g = try r.gpa.create(Generation);
    errdefer r.gpa.destroy(g);
    const client = try r.driver.open(io, &config);
    g.* = .{ .client = client, .number = 1, .connection = c };
    c.current = g;

    r.mutex.lockUncancelable(io);
    const lost = r.refusal(id);
    if (lost == null) {
        r.connections.append(&c.node);
        r.generations.append(&g.node);
        if (std.debug.runtime_safety) r.home.store(@intFromPtr(r), .monotonic);
    }
    r.mutex.unlock(io);
    if (lost) |err| {
        // Another call took the id meanwhile: this client goes.
        client.close(io);
        client.deinit();
        return refuse(d, err, id);
    }
}

/// Connects the connection `id`: the network and the login, under the
/// deadline of `ctx`. Nothing to do when it is active; after a failure it
/// may come again, with the same client. The driver's text of a failure is
/// in `connectionStats(io, id).last_failure` and in the log.
pub fn connect(r: *Registry, io: Io, ctx: core.Context, id: []const u8) Error!void {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    const c = switch (r.awaitTurn(io, ctx, id, .active, null) catch |err| {
        r.mutex.unlock(io);
        return err;
    }) {
        .done => {
            r.mutex.unlock(io);
            return;
        },
        .mine => |c| c,
    };
    const before = c.state;
    c.busy = true;
    c.state = .connecting;
    const g = c.current.?;
    generation.retain(g);
    r.mutex.unlock(io);

    var d: Diagnostics = .{};
    const connected = g.client.connect(io, ctx, &d);

    var failed: ?errors.DriverError = null;
    r.mutex.lockUncancelable(io);
    const result: Error!void = result: {
        if (r.state != .running) {
            c.state = before;
            break :result error.ShuttingDown;
        }
        connected catch |err| {
            c.state = .failed;
            c.last_failure = .init(err, d.message());
            failed = err;
            break :result err;
        };
        c.state = .active;
        g.state = .active;
    };
    c.busy = false;
    r.cond.broadcast(io);
    const free = generation.drop(r, io, g);
    r.mutex.unlock(io);
    if (free) generation.destroy(r, g);
    if (failed) |err| Warning.log(.{ .connect_failed = .{ .id = id, .err = err, .message = d.message() } });
    return result;
}

/// Replaces the settings of the connection `id`: opens a client with
/// `config` and connects it under `ctx`, publishes it as the new current
/// generation, then waits until the leases of the old one come back, for
/// `Options.drain_timeout` at the most, and closes it; leases left get
/// `Closed`, and the log a warning. An active connection whose current
/// settings are these has nothing to do: a repeat of the same event
/// changes nothing. A registered or failed connection takes a fresh client
/// even with the same settings. On a failure the current generation stays
/// and the state does not change; `config.diagnostics`,
/// `connectionStats(io, id).last_failure` and the log say why.
pub fn replaceConnection(r: *Registry, io: Io, ctx: core.Context, id: []const u8, config: ConnectionConfig) Error!void {
    r.checkUse(io);
    const d = config.diagnostics;
    if (d) |x| x.* = .{};
    const print = fingerprint.of(&r.key, config.uri, config.password);
    r.mutex.lockUncancelable(io);
    const c = switch (r.awaitTurn(io, ctx, id, .{ .same = &print }, d) catch |err| {
        r.mutex.unlock(io);
        return err;
    }) {
        .done => {
            r.mutex.unlock(io);
            return;
        },
        .mine => |c| c,
    };
    c.busy = true;
    const number = c.current.?.number + 1;
    r.mutex.unlock(io);
    defer r.endTurn(io, c);

    // The driver's text of a failure goes to `config.diagnostics`,
    // `last_failure` and the log.
    var failure: Diagnostics = .{};
    var settings = config;
    settings.diagnostics = &failure;
    const fresh = try r.gpa.create(Generation);
    const client = r.driver.open(io, &settings) catch |err| {
        r.gpa.destroy(fresh);
        r.mutex.lockUncancelable(io);
        c.last_failure = .init(err, failure.message());
        r.mutex.unlock(io);
        report(id, err, &failure, d);
        return err;
    };
    // Its own lease, while it connects.
    fresh.* = .{ .client = client, .number = number, .connection = c, .leases = 1 };
    r.mutex.lockUncancelable(io);
    const stopping = r.state != .running;
    if (!stopping) r.generations.append(&fresh.node);
    r.mutex.unlock(io);
    if (stopping) {
        client.close(io);
        generation.destroy(r, fresh);
        return fail(d, error.ShuttingDown, "odm: the registry is shutting down", .{});
    }

    const connected = client.connect(io, ctx, &failure);

    r.mutex.lockUncancelable(io);
    if (r.state != .running) {
        r.abandon(io, fresh);
        r.mutex.unlock(io);
        _ = generation.finishRetire(r, io, fresh, Io.Clock.awake.now(io), .pending);
        return fail(d, error.ShuttingDown, "odm: the registry is shutting down", .{});
    }
    connected catch |err| {
        // The rollback: the new generation goes, the current one stays.
        r.abandon(io, fresh);
        c.last_failure = .init(err, failure.message());
        r.mutex.unlock(io);
        _ = generation.finishRetire(r, io, fresh, Io.Clock.awake.now(io), .pending);
        report(id, err, &failure, d);
        return err;
    };
    // The publication, under one lock: from now on sessions get only the
    // new generation.
    const old = c.current.?;
    c.current = fresh;
    c.fingerprint = print;
    c.state = .active;
    fresh.state = .active;
    const free = generation.drop(r, io, fresh);
    std.debug.assert(!free);
    generation.beginRetire(io, old, .live);
    r.mutex.unlock(io);

    const until = Io.Clock.awake.now(io).addDuration(r.options.drain_timeout);
    const retired = generation.finishRetire(r, io, old, until, .live);
    if (retired.closer) if (retired.forced) |left| {
        Warning.log(.{ .forced = .{ .id = id, .generation = number - 1, .leases = left, .after = r.options.drain_timeout } });
    };
}

/// Removes the connection `id`, which no tenant may be bound to
/// (`ConnectionInUse`): its id finds nothing at once, then its generation
/// drains, for `Options.drain_timeout` at the most, and closes. It waits
/// for the operation on the connection in progress, if any, until its task
/// is canceled; nothing changes before the removal begins.
pub fn removeConnection(r: *Registry, io: Io, id: []const u8) Error!void {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    const c = switch (r.awaitTurn(io, .root, id, .never, null) catch |err| {
        r.mutex.unlock(io);
        return err;
    }) {
        .done => unreachable,
        .mine => |c| c,
    };
    if (c.tenants > 0) {
        r.mutex.unlock(io);
        return error.ConnectionInUse;
    }
    r.connections.remove(&c.node);
    r.removing += 1;
    c.state = .removing;
    var it = r.generations.first;
    while (it) |node| : (it = node.next) {
        const g = Generation.of(node);
        if (g.connection == c) g.connection = null;
    }
    const current = c.current.?;
    c.current = null;
    const number = current.number;
    generation.beginRetire(io, current, .live);
    // The calls that wait for this id look again, and find it gone.
    r.cond.broadcast(io);
    r.mutex.unlock(io);

    const until = Io.Clock.awake.now(io).addDuration(r.options.drain_timeout);
    const retired = generation.finishRetire(r, io, current, until, .live);
    r.mutex.lockUncancelable(io);
    r.removing -= 1;
    r.mutex.unlock(io);
    if (retired.closer) if (retired.forced) |left| {
        Warning.log(.{ .forced = .{ .id = id, .generation = number, .leases = left, .after = r.options.drain_timeout } });
    };
    c.destroy(r.gpa);
}

/// One round trip to the server of the connection `id`, through its current
/// generation, under the deadline of `ctx`.
pub fn ping(r: *Registry, io: Io, ctx: core.Context, id: []const u8) Error!void {
    r.checkUse(io);
    const g = try r.lease(io, id);
    defer generation.release(r, io, g);
    return g.client.ping(io, ctx, null);
}

/// A snapshot of the registry.
pub fn stats(r: *Registry, io: Io) Stats {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    var result: Stats = .{
        .connections = .{ .registered = 0, .connecting = 0, .active = 0, .failed = 0, .removing = r.removing },
        .draining = 0,
        .forced = r.forced,
        .leases = 0,
        .tenants = 0,
        .operations = r.operations.load(.monotonic),
        .operation_errors = r.operation_errors.load(.monotonic),
    };
    var it = r.connections.first;
    while (it) |node| : (it = node.next) {
        const c = Connection.of(node);
        switch (c.state) {
            .registered => result.connections.registered += 1,
            .connecting => result.connections.connecting += 1,
            .active => result.connections.active += 1,
            .failed => result.connections.failed += 1,
            // Out of the list: counted in `removing`.
            .removing => {},
        }
        result.tenants += c.tenants;
    }
    var gens = r.generations.first;
    while (gens) |node| : (gens = node.next) {
        const g = Generation.of(node);
        result.leases += g.leases;
        if (g.state == .draining or g.state == .closed) result.draining += 1;
    }
    return result;
}

/// A snapshot of the connection `id`. It takes a lease of the current
/// generation for the call, to read the pool of its client out of the
/// lock.
pub fn connectionStats(r: *Registry, io: Io, id: []const u8) Error!ConnectionStats {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    if (r.state != .running) {
        r.mutex.unlock(io);
        return error.ShuttingDown;
    }
    const c = r.find(id) orelse {
        r.mutex.unlock(io);
        return error.ConnectionNotFound;
    };
    const g = c.current.?;
    var result: ConnectionStats = .{
        .state = c.state,
        .generation = g.number,
        .leases = 0,
        .draining = 0,
        .tenants = c.tenants,
        .pool = null,
        .last_failure = c.last_failure,
    };
    var it = r.generations.first;
    while (it) |node| : (it = node.next) {
        const other = Generation.of(node);
        if (other.connection != c) continue;
        result.leases += other.leases;
        if (other != g and (other.state == .draining or other.state == .closed)) result.draining += 1;
    }
    generation.retain(g);
    r.mutex.unlock(io);
    result.pool = g.client.stats();
    generation.release(r, io, g);
    return result;
}

/// In safe builds: a call on a copy of the registry moved after its first
/// `registerConnection`, or on another `std.Io` than the one of `init`,
/// panics. Every call into the registry, its sessions and its cursors
/// checks it first.
pub fn checkUse(r: *const Registry, io: Io) void {
    if (!std.debug.runtime_safety) return;
    const home = r.home.load(.monotonic);
    if (home != 0 and home != @intFromPtr(r)) @panic("zefir-odm: Registry moved after its first registerConnection(): keep it where it was");
    // Two instances of one implementation share the table, so the
    // instance counts too.
    if (io.vtable != r.io.vtable or io.userdata != r.io.userdata) @panic("zefir-odm: a call on another std.Io than the registry's: pass the io of Registry.init");
}

/// What a call that needs a connection to itself finds once nothing else
/// holds it.
const Turn = union(enum) {
    /// The connection is as the call wants it: nothing to do.
    done,
    /// The call holds the connection until it clears `busy`.
    mine: *Connection,
};

/// When a call has nothing to do, so that it neither waits nor works.
const Skip = union(enum) {
    never,
    /// An active connection: `connect`.
    active,
    /// An active connection whose settings have this fingerprint:
    /// `replaceConnection`.
    same: *const fingerprint.Fingerprint,
};

/// The connection `id` for a call that needs it to itself, under the lock,
/// which the wait lets go: while another operation holds it, the call
/// waits on the condition, within the deadline of `ctx` and until its task
/// is canceled, and looks the id up again after each wake, since the
/// connection may have gone or changed meanwhile.
fn awaitTurn(r: *Registry, io: Io, ctx: core.Context, id: []const u8, skip: Skip, d: ?*Diagnostics) Error!Turn {
    while (true) {
        if (r.state != .running) return fail(d, error.ShuttingDown, "odm: the registry is shutting down", .{});
        const c = r.find(id) orelse return fail(d, error.ConnectionNotFound, "odm: no connection has this id", .{});
        switch (skip) {
            .never => {},
            .active => if (c.state == .active) return .done,
            .same => |print| if (c.state == .active and fingerprint.eql(print, &c.fingerprint)) return .done,
        }
        if (!c.busy) return .{ .mine = c };
        if (ctx.isCancelled()) return fail(d, error.Cancelled, "odm: the token was canceled while the call waited for another operation on the connection", .{});
        if (ctx.isExpired(Io.Clock.awake.now(io))) return fail(d, error.DeadlineExceeded, "odm: the deadline passed while the call waited for another operation on the connection", .{});
        r.cond.waitTimeout(io, &r.mutex, step(io, ctx.deadline)) catch |err| switch (err) {
            // The deadline, a step of a far one, or a wake for another
            // change: the loop looks again.
            error.Timeout => {},
            error.Canceled => {
                io.recancel();
                return fail(d, error.Cancelled, "odm: the task was canceled while the call waited for another operation on the connection", .{});
            },
        };
    }
}

/// Lets the next operation on `c` go.
fn endTurn(r: *Registry, io: Io, c: *Connection) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    c.busy = false;
    r.cond.broadcast(io);
}

/// Under the lock: a new generation that will not be published gives its
/// own lease back, and its `finishRetire` closes it.
fn abandon(r: *Registry, io: Io, g: *Generation) void {
    generation.beginRetire(io, g, .pending);
    const free = generation.drop(r, io, g);
    std.debug.assert(!free);
}

/// The failure of a replacement, for the caller and the log.
fn report(id: []const u8, err: errors.DriverError, failure: *const Diagnostics, d: ?*Diagnostics) void {
    if (d) |x| x.* = failure.*;
    Warning.log(.{ .connect_failed = .{ .id = id, .err = err, .message = failure.message() } });
}

/// A lease of the current generation of `id` for one call.
fn lease(r: *Registry, io: Io, id: []const u8) Error!*Generation {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.state != .running) return error.ShuttingDown;
    const c = r.find(id) orelse return error.ConnectionNotFound;
    const g = c.current.?;
    generation.retain(g);
    return g;
}

/// The connection of `id`, under the lock.
fn find(r: *Registry, id: []const u8) ?*Connection {
    var it = r.connections.first;
    while (it) |node| : (it = node.next) {
        const c = Connection.of(node);
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Why a registration of `id` cannot go on, under the lock.
fn refusal(r: *Registry, id: []const u8) ?Error {
    if (r.state != .running) return error.ShuttingDown;
    if (r.find(id) != null) return error.ConnectionExists;
    return null;
}

fn refuse(d: ?*Diagnostics, err: Error, id: []const u8) Error {
    return switch (err) {
        error.ConnectionExists => fail(d, err, "odm: connection {s} exists already", .{id}),
        else => fail(d, err, "odm: the registry is shutting down", .{}),
    };
}

/// `err`, with the text in `d`.
fn fail(d: ?*Diagnostics, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
    if (d) |x| x.set(null, null, fmt, args);
    return err;
}

/// Where the next wait toward `deadline` ends: at the deadline, and an hour
/// from now at the most, since some `std.Io` implementations overflow on a
/// far one.
fn step(io: Io, deadline: ?core.Deadline) Io.Timeout {
    const far: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(3600));
    const end = if (deadline) |x| x.earliest(far) else far;
    return end.toTimeout();
}
