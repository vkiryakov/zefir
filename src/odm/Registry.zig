//! `odm.Registry`: the connections of a service and their tenants. A
//! connection is a server and a login, one client of the driver with its
//! pool; it lives in generations, and a replacement opens a new one while
//! the old one drains. A tenant is a connection and a database.
//!
//! ```zig
//! var registry = odm.Registry.init(gpa, io, driver.driver(), .{});
//! defer registry.deinit(io);
//! try registry.registerConnection(io, "shared-1", .{ .uri = uri, .password = password });
//! try registry.connect(io, ctx, "shared-1");
//! try registry.provisionTenant(io, ctx, .{
//!     .tenant = "acme",
//!     .connection = .{ .existing = "shared-1" },
//!     .database = "acme",
//!     .version = 1,
//! });
//! var acme = try registry.tenant(io, "acme");
//! defer acme.deinit(io);
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
//! `provisionTenant` binds a tenant, on an event of the application with a
//! version: to a connection registered already (`.existing`), or to one of
//! its own (`.new`), which it registers and connects. The provisionings of
//! a tenant take turns; an older version than the tenant's changes nothing,
//! and the same event again neither. The binding is published at once,
//! whole, once its connection works. `tenant(io, id)` gives a
//! `Session` on the tenant's database, with a lease of the current
//! generation of its connection; `removeTenant` unbinds it. A connection
//! that tenants are bound to cannot be removed.
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
const binding = @import("registry/binding.zig");
const Binding = binding.Binding;
const Provisioning = binding.Provisioning;
const Session = @import("Session.zig");
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
/// The tenants by id; each key is the id inside its binding.
bindings: Bindings = .empty,
/// The slots of `bindings` promised to provisionings in progress, so that
/// none runs out of memory at its publication.
reserved: u32 = 0,
/// The provisionings in progress, one per tenant at most.
provisioning: List = .{},
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

const Bindings = std.StringHashMapUnmanaged(*Binding);

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

/// A provisioning of a tenant: an event of the application, such as "a
/// new tenant" or "the tenant moved", with its version. It is borrowed
/// for the call only: the registry copies the tenant id and the database
/// name, and keeps no password. zefir-log writes it as "[REDACTED]".
pub const Provision = struct {
    /// 1 to 128 bytes of visible ASCII, 0x21 to 0x7E.
    tenant: []const u8,
    connection: union(enum) {
        /// A connection registered already, which the tenant shares with
        /// others: one login on one server for all of them.
        existing: []const u8,
        /// A connection of the tenant's own: a server of its own, or a
        /// login of its own on a shared server.
        new: NewConnection,
    },
    /// The tenant's database: 1 to 63 bytes of UTF-8 without / \ . " $, a
    /// space or NUL, and never admin, local or config.
    database: []const u8,
    /// Grows with each event of the tenant: a lower one than the tenant's
    /// changes nothing (`StaleVersion`), and the same one with the same
    /// settings is the event again, which changes nothing either.
    version: u64,
    /// Why the provisioning failed: a text of odm or of the driver.
    diagnostics: ?*Diagnostics = null,

    pub const zefir_sensitive = true;
};

/// A connection that a provisioning registers and connects for its
/// tenant.
pub const NewConnection = struct {
    /// 1 to 64 bytes of A–Z a–z 0–9 _ - . :
    id: []const u8,
    /// The connection string of the driver, as in `ConnectionConfig`.
    uri: []const u8,
    /// The password of the user of `uri`, when the string holds none.
    password: ?[]const u8 = null,
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
/// first: in safe builds one left panics, and in the others the memory of
/// its generation stays, a leak rather than a use after free.
pub fn deinit(r: *Registry, io: Io) void {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    const state = r.state;
    var leases: usize = 0;
    var it = r.generations.first;
    while (it) |node| : (it = node.next) leases += Generation.of(node).leases;
    r.mutex.unlock(io);
    // Before the shutdown, which would close their generations by force.
    if (std.debug.runtime_safety and leases > 0) @panic("zefir-odm: Registry.deinit() with sessions or cursors left: deinit them first");
    switch (state) {
        .running => r.shutdown(io, .now(io, .awake)) catch {},
        .stopping => r.shut.waitUncancelable(io),
        .stopped => {},
    }
    // Every generation is closed. One still in the list holds leases, a
    // mistake of the program: its memory stays, a leak rather than a use
    // after free.
    var tenants = r.bindings.valueIterator();
    while (tenants.next()) |b| r.gpa.destroy(b.*);
    r.bindings.deinit(r.gpa);
    while (r.connections.popFirst()) |node| Connection.of(node).destroy(r.gpa);
    r.* = undefined;
}

/// Stops the registry by `deadline`, the bean contract of `zefir.App`. From
/// now on `registerConnection`, `connect`, `replaceConnection`,
/// `removeConnection`, `ping`, `connectionStats`, `provisionTenant`,
/// `removeTenant`, `tenant` and the calls waiting for their turn get
/// `ShuttingDown`. Generations that never connected close
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
    _ = try r.register(io, id, config, null, .free);
}

/// Whether a connection that `register` puts in the list comes held by
/// its caller.
const Hold = enum {
    /// Any call may take its turn at once.
    free,
    /// Its caller holds its turn (`busy`) and ends it: a provisioning
    /// connects the connection it made before anyone else does.
    held,
};

/// The body of `registerConnection`, `id` checked: the fingerprint of
/// `config`, unless the caller gives it, and a client of the driver; the
/// record goes in the list when `id` is still free then.
fn register(r: *Registry, io: Io, id: []const u8, config: ConnectionConfig, given: ?*const fingerprint.Fingerprint, hold: Hold) Error!*Connection {
    const d = config.diagnostics;
    // A known id needs no client.
    r.mutex.lockUncancelable(io);
    const vacant = r.mayRegister(id);
    r.mutex.unlock(io);
    vacant catch |err| return refuse(d, err, id);

    const print = if (given) |p| p.* else fingerprint.of(&r.key, config.uri, config.password);
    const c = try Connection.create(r.gpa, id, print);
    errdefer c.destroy(r.gpa);
    const g = try r.gpa.create(Generation);
    errdefer r.gpa.destroy(g);
    const client = try r.driver.open(io, &config);
    g.* = .{ .client = client, .number = 1, .connection = c };
    c.current = g;
    c.busy = hold == .held;

    r.mutex.lockUncancelable(io);
    const still = r.mayRegister(id);
    if (still) |_| {
        r.connections.append(&c.node);
        r.generations.append(&g.node);
        if (std.debug.runtime_safety) r.home.store(@intFromPtr(r), .monotonic);
    } else |_| {}
    r.mutex.unlock(io);
    still catch |err| {
        // Another call took the id meanwhile: this client goes.
        client.close(io);
        client.deinit();
        return refuse(d, err, id);
    };
    return c;
}

/// Connects the connection `id`: the network and the login, under the
/// deadline of `ctx`. Nothing to do when it is active; after a failure it
/// may come again, with the same client. The driver's text of a failure is
/// in `connectionStats(io, id).last_failure` and in the log.
pub fn connect(r: *Registry, io: Io, ctx: core.Context, id: []const u8) Error!void {
    r.checkUse(io);
    return r.ready(io, ctx, id, null);
}

/// The connection `id` connected, for `connect` and a provisioning: once
/// it is its turn, nothing to do for an active one, else a connect under
/// `ctx`. `d` gets the text of a failure.
fn ready(r: *Registry, io: Io, ctx: core.Context, id: []const u8, d: ?*Diagnostics) Error!void {
    r.mutex.lockUncancelable(io);
    const c = switch (r.awaitTurn(io, ctx, id, .active, d) catch |err| {
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
    return r.connectHeld(io, ctx, c, d, .keep);
}

/// What a failed connect does to its connection.
const OnFailure = enum {
    /// It stays, failed, for a connect to come again.
    keep,
    /// It goes: the provisioning that made it for this call rolls it back.
    remove,
};

/// The connect of `c`, called under the lock, which it lets go, with the
/// turn of `c` held (`busy`), which it ends. The current generation holds
/// a lease for the call of the driver, made out of the lock. The driver's
/// text of a failure goes to `last_failure`, the log and `d`.
fn connectHeld(r: *Registry, io: Io, ctx: core.Context, c: *Connection, d: ?*Diagnostics, on_failure: OnFailure) Error!void {
    if (r.state != .running) {
        // The shutdown may have closed its generation already.
        c.busy = false;
        r.cond.broadcast(io);
        r.mutex.unlock(io);
        return fail(d, error.ShuttingDown, "odm: the registry is shutting down", .{});
    }
    const before = c.state;
    c.state = .connecting;
    const g = c.current.?;
    generation.retain(g);
    r.mutex.unlock(io);

    var failure: Diagnostics = .{};
    const connected = g.client.connect(io, ctx, &failure);

    var failed: ?errors.DriverError = null;
    var removed = false;
    r.mutex.lockUncancelable(io);
    const result: Error!void = result: {
        if (r.state != .running) {
            c.state = before;
            break :result error.ShuttingDown;
        }
        connected catch |err| {
            c.state = .failed;
            c.last_failure = .init(err, failure.message());
            failed = err;
            if (on_failure == .remove) {
                // No tenant can be bound to it: it never was active.
                _ = r.takeOut(io, c, .pending);
                removed = true;
            }
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
    if (failed) |err| {
        if (d) |x| x.* = failure;
        Warning.log(.{ .connect_failed = .{ .id = c.id, .err = err, .message = failure.message() } });
    } else if (result) |_| {} else |_| {
        // The shutdown came while it connected.
        if (d) |x| x.set(null, null, "odm: the registry is shutting down", .{});
    }
    // A generation that never connected closes at once, never by force.
    if (removed) _ = r.retire(io, c, g, Io.Clock.awake.now(io), .pending);
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
    const current = r.takeOut(io, c, .live);
    const number = current.number;
    r.mutex.unlock(io);

    const until = Io.Clock.awake.now(io).addDuration(r.options.drain_timeout);
    const retired = r.retire(io, c, current, until, .live);
    if (retired.closer) if (retired.forced) |left| {
        Warning.log(.{ .forced = .{ .id = id, .generation = number, .leases = left, .after = r.options.drain_timeout } });
    };
}

/// Under the lock: takes `c`, which no tenant is bound to, out of the
/// list, so that its id finds nothing at once, and begins to take its
/// current generation out of service; `retire` does the rest.
fn takeOut(r: *Registry, io: Io, c: *Connection, kind: generation.Kind) *Generation {
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
    generation.beginRetire(io, current, kind);
    // The calls that wait for this id look again, and find it gone.
    r.cond.broadcast(io);
    return current;
}

/// The rest of a removal after `takeOut`, out of the lock: `g`, the
/// generation it gave, leaves service by `until`, then the record goes.
fn retire(r: *Registry, io: Io, c: *Connection, g: *Generation, until: Io.Timestamp, kind: generation.Kind) generation.Retired {
    const retired = generation.finishRetire(r, io, g, until, kind);
    r.mutex.lockUncancelable(io);
    r.removing -= 1;
    r.mutex.unlock(io);
    c.destroy(r.gpa);
    return retired;
}

/// One round trip to the server of the connection `id`, through its current
/// generation, under the deadline of `ctx`.
pub fn ping(r: *Registry, io: Io, ctx: core.Context, id: []const u8) Error!void {
    r.checkUse(io);
    const g = try r.lease(io, id);
    defer generation.release(r, io, g);
    return g.client.ping(io, ctx, null);
}

/// Binds a tenant to a connection and a database, on an event of the
/// application with a version. The names are checked first, before any
/// I/O. Then the tenant's queue: one provisioning of a tenant at a time,
/// and the next one waits for its turn within the deadline of `ctx` and
/// until its task is canceled. Then the version, against the tenant's
/// binding, before the network:
///
/// - no binding, or one of a lower version: the request is applied;
/// - a lower version than the binding's: `StaleVersion`, and nothing
///   changes;
/// - the same version with the same settings — the same database and the
///   same connection, named the same way: the event again, and nothing to
///   do;
/// - the same version with other settings: `ProvisioningConflict`.
///
/// To apply it, the connection is made ready: a known one is connected
/// when it is not yet. A `.new` one with an unknown id is registered and
/// connected; with a known id it is taken as it is when its settings are
/// the same, and else `ProvisioningConflict`: `replaceConnection` changes
/// them. Then the binding is published at once, whole: `tenant()` finds
/// the old one or the new one, never a half. On a failure the old binding
/// stays, and a new connection that this call made goes again; the
/// driver's text or odm's is in `request.diagnostics`.
pub fn provisionTenant(r: *Registry, io: Io, ctx: core.Context, request: Provision) Error!void {
    r.checkUse(io);
    const d = request.diagnostics;
    if (d) |x| x.* = .{};
    // The names, before any I/O.
    if (names.tenantId(request.tenant)) |problem| return fail(d, error.InvalidArgument, "odm: {s}", .{problem});
    if (names.database(request.database)) |problem| return fail(d, error.InvalidArgument, "odm: {s}", .{problem});
    var print: ?fingerprint.Fingerprint = null;
    const id = switch (request.connection) {
        .existing => |id| id,
        .new => |new| new: {
            if (names.connectionId(new.id)) |problem| return fail(d, error.InvalidArgument, "odm: {s}", .{problem});
            print = fingerprint.of(&r.key, new.uri, new.password);
            break :new new.id;
        },
    };
    // The memory of the publication, before any I/O: a provisioning never
    // runs out of it once its connection is ready.
    const fresh = try Binding.create(r.gpa, request.tenant, request.database, request.version, print);
    var published = false;
    defer if (!published) r.gpa.destroy(fresh);

    // The queue of the tenant: the version checked below stays the
    // tenant's until the publication.
    var mine: Provisioning = .{ .tenant = request.tenant };
    r.mutex.lockUncancelable(io);
    r.awaitTenant(io, ctx, request.tenant, d) catch |err| {
        r.mutex.unlock(io);
        return err;
    };
    r.provisioning.append(&mine.node);
    defer r.endProvisioning(io, &mine);
    // The version, before the network.
    const verdict = r.judge(request, id, if (print) |*p| p else null);
    if (verdict == .apply) {
        // A slot of the table for the publication.
        r.reserveTenant(io) catch |err| {
            r.mutex.unlock(io);
            return err;
        };
        mine.reserved = true;
    }
    r.mutex.unlock(io);
    switch (verdict) {
        .apply => {},
        .same => return,
        .stale => |known| return fail(d, error.StaleVersion, "odm: version {d} is older than the tenant's version {d}", .{ request.version, known }),
        .conflict => return fail(d, error.ProvisioningConflict, "odm: version {d} is the tenant's version, with other settings", .{request.version}),
    }

    // The connection, ready.
    switch (request.connection) {
        .existing => try r.ready(io, ctx, id, d),
        .new => |new| try r.readyNew(io, ctx, new, &print.?, d),
    }

    // The publication, under one lock.
    r.mutex.lockUncancelable(io);
    const old = r.publish(fresh, id);
    if (old) |_| {
        // The slot is the binding's now, or the old one's was.
        mine.reserved = false;
        r.reserved -= 1;
    } else |_| {}
    r.mutex.unlock(io);
    const replaced = old catch |err| return switch (err) {
        error.ConnectionNotFound => fail(d, err, "odm: the connection was removed while the tenant was provisioned", .{}),
        error.ShuttingDown => fail(d, err, "odm: the registry is shutting down", .{}),
    };
    published = true;
    if (replaced) |b| r.gpa.destroy(b);
}

/// What the version of a provisioning makes of the tenant's binding.
const Verdict = union(enum) {
    /// No binding, or one of a lower version: the request goes on.
    apply,
    /// The same version and settings: nothing to do.
    same,
    /// A lower version than the binding's, which it names.
    stale: u64,
    /// The same version, other settings.
    conflict,
};

/// The version of `request` against the tenant's binding, under the lock.
fn judge(r: *Registry, request: Provision, id: []const u8, print: ?*const fingerprint.Fingerprint) Verdict {
    const b = r.bindings.get(request.tenant) orelse return .apply;
    if (request.version < b.version) return .{ .stale = b.version };
    if (request.version > b.version) return .apply;
    return if (b.sameAs(request.database, id, print)) .same else .conflict;
}

/// Under the lock, which the wait lets go: until no provisioning of
/// `tenant_id` is in progress, within the deadline of `ctx` and until the
/// task is canceled. `ShuttingDown` once the registry stops, also for the
/// calls that wait.
fn awaitTenant(r: *Registry, io: Io, ctx: core.Context, tenant_id: []const u8, d: ?*Diagnostics) Error!void {
    while (true) {
        if (r.state != .running) return fail(d, error.ShuttingDown, "odm: the registry is shutting down", .{});
        if (!r.isProvisioning(tenant_id)) return;
        if (ctx.isCancelled()) return fail(d, error.Cancelled, "odm: the token was canceled while the call waited for another provisioning of the tenant", .{});
        if (ctx.isExpired(Io.Clock.awake.now(io))) return fail(d, error.DeadlineExceeded, "odm: the deadline passed while the call waited for another provisioning of the tenant", .{});
        r.cond.waitTimeout(io, &r.mutex, step(io, ctx.deadline)) catch |err| switch (err) {
            // The deadline, a step of a far one, or a wake for another
            // change: the loop looks again.
            error.Timeout => {},
            error.Canceled => {
                io.recancel();
                return fail(d, error.Cancelled, "odm: the task was canceled while the call waited for another provisioning of the tenant", .{});
            },
        };
    }
}

/// Whether a provisioning of `tenant_id` is in progress, under the lock.
fn isProvisioning(r: *Registry, tenant_id: []const u8) bool {
    var it = r.provisioning.first;
    while (it) |node| : (it = node.next) {
        if (std.mem.eql(u8, Provisioning.of(node).tenant, tenant_id)) return true;
    }
    return false;
}

/// The end of the provisioning `mine`, with the lock: the slot it reserved
/// goes back, and the next one of its tenant may go.
fn endProvisioning(r: *Registry, io: Io, mine: *Provisioning) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.provisioning.remove(&mine.node);
    if (mine.reserved) r.reserved -= 1;
    r.cond.broadcast(io);
}

/// The connection of a `.new`. A known id with the same settings is taken
/// as `.existing` would be, and with others it is `ProvisioningConflict`.
/// An unknown one is registered by this call and connected in its turn,
/// which no other call takes first, and a failed connect takes it out
/// again.
fn readyNew(r: *Registry, io: Io, ctx: core.Context, new: NewConnection, print: *const fingerprint.Fingerprint, d: ?*Diagnostics) Error!void {
    const config: ConnectionConfig = .{ .uri = new.uri, .password = new.password, .diagnostics = d };
    while (true) {
        r.mutex.lockUncancelable(io);
        if (r.state == .running and r.find(new.id) == null) {
            r.mutex.unlock(io);
            const c = r.register(io, new.id, config, print, .held) catch |err| switch (err) {
                // Another call registered it meanwhile: look again.
                error.ConnectionExists => {
                    if (d) |x| x.* = .{};
                    continue;
                },
                else => return err,
            };
            r.mutex.lockUncancelable(io);
            return r.connectHeld(io, ctx, c, d, .remove);
        }
        const c = switch (r.awaitTurn(io, ctx, new.id, .{ .settings = print }, d) catch |err| {
            r.mutex.unlock(io);
            // Its maker took it out after a failed connect: make it anew.
            if (err == error.ConnectionNotFound) {
                if (d) |x| x.* = .{};
                continue;
            }
            return err;
        }) {
            .done => {
                r.mutex.unlock(io);
                return;
            },
            .mine => |c| c,
        };
        c.busy = true;
        return r.connectHeld(io, ctx, c, d, .keep);
    }
}

/// The publication of a provisioning, under the lock: `fresh` takes the
/// place of the tenant's binding if the connection `id` is still there
/// and active, else `ConnectionNotFound`, and nothing changes. The old
/// binding, if any, is the caller's to free out of the lock.
fn publish(r: *Registry, fresh: *Binding, id: []const u8) error{ ShuttingDown, ConnectionNotFound }!?*Binding {
    if (r.state != .running) return error.ShuttingDown;
    // A removal may have come since the connection was ready: the binding
    // never points to a connection that is gone.
    const c = r.find(id) orelse return error.ConnectionNotFound;
    if (c.state != .active) return error.ConnectionNotFound;
    fresh.connection = c;
    c.tenants += 1;
    // A new tenant takes the slot reserved before.
    const entry = r.bindings.getOrPutAssumeCapacity(fresh.tenant());
    const old: ?*Binding = if (entry.found_existing) entry.value_ptr.* else null;
    if (old) |b| b.connection.tenants -= 1;
    // The key is the id inside the binding, which lives as long as it.
    entry.key_ptr.* = fresh.tenant();
    entry.value_ptr.* = fresh;
    return old;
}

/// Under the lock, which it may let go and take again: one slot of the
/// table of tenants for a provisioning, until its publication or its
/// failure, so that a publication never runs out of memory once its
/// connection is ready. A full table grows out of the lock: an allocator
/// may take a lock of its own, and the registry's lock is a leaf.
fn reserveTenant(r: *Registry, io: Io) Allocator.Error!void {
    while (r.bindings.available <= r.reserved) {
        const want = (r.bindings.count() + r.reserved) * 2 + 8;
        r.mutex.unlock(io);
        var bigger: Bindings = .empty;
        const grown = bigger.ensureTotalCapacity(r.gpa, want);
        r.mutex.lockUncancelable(io);
        try grown;
        if (r.bindings.available <= r.reserved and bigger.available > r.bindings.count() + r.reserved) {
            var it = r.bindings.iterator();
            while (it.next()) |entry| bigger.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
            std.mem.swap(Bindings, &r.bindings, &bigger);
        }
        // The old table, or a new one that another call made needless,
        // goes out of the lock.
        r.mutex.unlock(io);
        bigger.deinit(r.gpa);
        r.mutex.lockUncancelable(io);
    }
    r.reserved += 1;
}

/// Removes the tenant `tenant_id`: `tenant()` finds it no more, at once.
/// The sessions taken before work on until their `deinit`, and its
/// connection stays: `removeConnection` removes that one once no tenant
/// is bound to it. There is no version: the registry keeps no memory of
/// removed tenants, so a provisioning that comes later binds the tenant
/// again, whatever its version. A provisioning of the tenant in progress
/// is waited for first, until the task is canceled.
pub fn removeTenant(r: *Registry, io: Io, tenant_id: []const u8) Error!void {
    r.checkUse(io);
    r.mutex.lockUncancelable(io);
    const b: *Binding = b: {
        defer r.mutex.unlock(io);
        try r.awaitTenant(io, .root, tenant_id, null);
        const entry = r.bindings.fetchRemove(tenant_id) orelse return error.TenantNotFound;
        entry.value.connection.tenants -= 1;
        break :b entry.value;
    };
    r.gpa.destroy(b);
}

/// A session on the database of the tenant `tenant_id`, with a lease of
/// the current generation of its connection: give it back with
/// `session.deinit(io)`. `TenantNotFound` when no tenant has the id, also
/// for an id that no tenant can have. The parameter is not called
/// `tenant`: it would shadow this method.
pub fn tenant(r: *Registry, io: Io, tenant_id: []const u8) Error!Session {
    r.checkUse(io);
    // No tenant has a longer id: it is not even looked up.
    if (tenant_id.len > 128) return error.TenantNotFound;
    var s: Session = .{ .registry = r, .generation = undefined, .name_buf = undefined, .name_len = 0 };
    {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.state != .running) return error.ShuttingDown;
        const b = r.bindings.get(tenant_id) orelse return error.TenantNotFound;
        // A connection with a tenant is active, and stays so while the
        // registry runs: it cannot go, and a replacement publishes an
        // active generation.
        const g = b.connection.current.?;
        std.debug.assert(g.state == .active);
        generation.retain(g);
        s.generation = g;
        const name = b.database();
        @memcpy(s.name_buf[0..name.len], name);
        s.name_len = @intCast(name.len);
    }
    return s;
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
    /// An active connection, for a `.new` of a provisioning, whose
    /// settings must have this fingerprint, else `ProvisioningConflict`.
    settings: *const fingerprint.Fingerprint,
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
            .settings => |print| {
                if (!fingerprint.eql(print, &c.fingerprint)) return fail(d, error.ProvisioningConflict, "odm: connection {s} exists with other settings: change them with replaceConnection", .{id});
                if (c.state == .active) return .done;
            },
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

/// Whether a registration of `id` may go on, under the lock.
fn mayRegister(r: *Registry, id: []const u8) Error!void {
    if (r.state != .running) return error.ShuttingDown;
    if (r.find(id) != null) return error.ConnectionExists;
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
