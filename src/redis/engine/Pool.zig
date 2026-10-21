//! The connections of the client to its server, pooled: a call takes one
//! for its exchange (`checkOut`) and gives it back (`checkIn`). This is the
//! pool of zefir-mongo with the changes that Redis asks for:
//!
//! - At most `max_size` connections (`max_connections` of the client, 32
//!   by default), of which at most `max_connecting`, 2, are being opened at
//!   once. Connections open only when calls need them and stay open until
//!   an error, the server or `close` ends them: there is no least number
//!   of them and no idle time. Nothing runs in the background.
//! - A call that finds no connection waits in line, first come first
//!   served, until its deadline ends (`error.PoolExhausted`), its task is
//!   canceled (`error.Cancelled`) or the pool closes (`error.Closed`);
//!   without a deadline it waits as long as it takes. One that leaves
//!   passes its turn on.
//! - A call opens a connection outside the lock and gets the one it
//!   opened, so that opening one never holds up the calls that find an
//!   idle one. An opening that fails or is canceled frees its place.
//! - A connection of an older generation, or one its exchange left
//!   broken, closes at check-in.
//! - A connection that lay idle for 30 s or longer gets PING before it goes
//!   to a call, under the call's deadline: a server's `timeout` or a
//!   firewall may have closed it meanwhile, and there is no TCP keepalive
//!   to tell. Any reply, an error too (LOADING and BUSY refuse PING), means
//!   it is alive. The end of the stream or a broken reply closes it, and
//!   the call takes another or opens one, keeping its turn: this is no
//!   retry, since the call's command has not gone out. A deadline that
//!   passes meanwhile is `error.DeadlineExceeded`, and a canceled task
//!   `error.Cancelled`.
//! - A clear makes every connection of the generation stale, closing the
//!   idle ones at once, and pauses the pool; the calls in line get
//!   `error.Unavailable`. It comes from a network error on an established
//!   connection, which the caller names at check-in, and from a server
//!   that refuses the user of a new one; an error of an older generation
//!   is stale and clears nothing. A timeout, a cancelation, a reply that
//!   breaks RESP3 and one too large close their own connection only. With
//!   no monitor to find the server back, the first call to a paused pool
//!   opens one connection as a probe, at most once every 500 ms, and the
//!   others get `error.Unavailable` at once; a probe that succeeds makes
//!   the pool ready again.
//! - `close` refuses new calls and those in line (`error.Closed`), stops
//!   the openings, lets the exchanges in progress end within its time,
//!   then cuts them, and closes the connections last.
//!
//! A connection holds its `Entry`, the pool's part of it, as a field; the
//! pool opens connections through the caller's `Opener`, so that tests
//! run it on connections of their own.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const errors = @import("../errors.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const Address = @import("Address.zig");
const Attempt = @import("connect.zig").Attempt;
const time = @import("time.zig");
const log = std.log.scoped(.redis);
const Pool = @This();
const List = std.DoublyLinkedList;

/// The shortest time between two probes of a paused pool.
pub const probe_interval: Io.Duration = .fromMilliseconds(500);
/// How long a connection may lie idle before it is checked with PING.
pub const idle_check_after: Io.Duration = .fromSeconds(30);

options: Options,
mutex: Io.Mutex = .init,
state: State = .initialized,
generation: u64 = 0,
clears: u64 = 0,
/// Connections nobody uses, the one checked in last at the end.
idle: List = .{},
idle_count: usize = 0,
in_use: List = .{},
in_use_count: usize = 0,
/// The openings in progress, for `close` to stop.
opening: List = .{},
opening_count: usize = 0,
/// The calls waiting for a connection, first come first.
line: List = .{},
waiting: usize = 0,
/// The calls between `enter` and `leave`.
calls: usize = 0,
/// A probe of the paused pool is opening a connection.
probing: bool = false,
/// When the latest probe started.
last_probe: ?Io.Timestamp = null,
/// Set once the pool is closing and no call is left.
drained: Io.Event = .unset,
/// Set once `close` is done.
closed: Io.Event = .unset,

pub const Options = struct {
    /// The server, for messages.
    server: Address,
    /// `max_connections` of the client.
    max_size: u32 = 32,
    /// How many connections open at once at most.
    max_connecting: u32 = 2,
    /// How long a connection may lie idle before it is checked with PING:
    /// `idle_check_after`. Internal, not an option of the client: tests
    /// shorten it, before the first call.
    idle_check: Io.Duration = idle_check_after,
};

pub const State = enum { initialized, ready, paused, closing, closed };

/// The pool's part of a connection, which the connection holds as a
/// field: its place in a list, its generation, and how the pool closes it
/// or cuts its exchange.
pub const Entry = struct {
    node: List.Node = .{},
    hooks: *const Hooks,
    generation: u64 = 0,
    /// When it was checked in last, on the awake clock.
    idle_since: Io.Timestamp = .zero,

    pub const Hooks = struct {
        /// Closes and frees the connection.
        destroy: *const fn (entry: *Entry) void,
        /// Cuts its exchange in progress, from another task.
        cut: *const fn (entry: *Entry, io: Io) void,
        /// Sends PING on the connection, which lay idle, and waits for
        /// any reply until `deadline`; null: no limit.
        ping: *const fn (entry: *Entry, io: Io, deadline: ?core.Deadline) Liveness,
    };
};

/// What the PING of an idle connection found.
pub const Liveness = enum {
    /// A reply came: the connection goes to the call.
    alive,
    /// The stream ended or broke: the connection closes.
    dead,
    /// The deadline passed first.
    deadline,
    /// The task was canceled, and stays canceled.
    canceled,
};

/// How a call opens a connection: `open` returns the entry of the new
/// connection, or the client's error for the call, within `deadline`, the
/// call's, and the client's own `connect_timeout`. A canceled task gives
/// `error.Cancelled`, and stays canceled; an attempt that `close` stopped
/// gives `error.Closed`.
pub const Opener = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, io: Io, deadline: ?core.Deadline, attempt: *Attempt, d: ?*Diagnostics) Error!*Entry,
};

/// What an exchange left of the connection that `checkIn` takes back.
pub const After = union(enum) {
    /// It is as it was.
    ok,
    /// It is broken, as after a timeout: close it.
    broken,
    /// The server is gone: close it and clear the pool, for the reason
    /// given, which the log shows.
    clear: []const u8,
};

/// What the pool holds at a moment.
pub const Counts = struct {
    idle: usize,
    in_use: usize,
    opening: usize,
    waiting: usize,
    generation: u64,
    clears: u64,
};

pub fn init(options: Options) Pool {
    return .{ .options = options };
}

/// After `close`: frees nothing, since `close` closed every connection.
pub fn deinit(pool: *Pool) void {
    std.debug.assert(pool.state == .closed or pool.state == .initialized);
    std.debug.assert(pool.idle_count == 0 and pool.in_use_count == 0 and pool.opening_count == 0 and pool.calls == 0);
    pool.* = undefined;
}

/// Counts a call in, so that `close` waits for it; `error.Closed` once the
/// pool is closing. `leave` is the last thing the call does with the pool.
pub fn enter(pool: *Pool, io: Io, d: ?*Diagnostics) Error!void {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    switch (pool.state) {
        .closing, .closed => return fail(d, .checkout, error.Closed, "the client is closed", .{}),
        .initialized, .ready, .paused => {},
    }
    pool.calls += 1;
}

pub fn leave(pool: *Pool, io: Io) void {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    pool.calls -= 1;
    pool.signalDrained(io);
}

/// Whether `connect` has succeeded.
pub fn isConnected(pool: *Pool, io: Io) bool {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    return pool.state == .ready or pool.state == .paused;
}

/// Opens the first connection, for the client's `connect`, which calls
/// may not do before: the pool is ready from then on, and keeps the
/// connection idle.
pub fn connect(pool: *Pool, io: Io, opener: Opener, deadline: ?core.Deadline, d: ?*Diagnostics) Error!void {
    const entry = try pool.take(io, opener, deadline, .connect, d);
    pool.mutex.lockUncancelable(io);
    const closing = pool.state == .closing or pool.state == .closed;
    if (pool.state == .initialized) pool.state = .ready;
    pool.mutex.unlock(io);
    pool.checkIn(io, entry, .ok);
    if (closing) return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
}

/// A connection for one exchange: an idle one, or one the call opens,
/// waiting in line when there is neither, until `deadline`; null: as long
/// as it takes. Give it back with `checkIn`.
pub fn checkOut(pool: *Pool, io: Io, opener: Opener, deadline: ?core.Deadline, d: ?*Diagnostics) Error!*Entry {
    return pool.take(io, opener, deadline, .call, d);
}

/// Takes `entry` back: idle, or closed when it is stale or `after` says
/// so; `after.clear` clears the pool too. While the pool is closing, an
/// idle connection waits for the end of `close`.
pub fn checkIn(pool: *Pool, io: Io, entry: *Entry, after: After) void {
    var dead: List = .{};
    var cleared = false;
    pool.mutex.lockUncancelable(io);
    pool.in_use.remove(&entry.node);
    pool.in_use_count -= 1;
    const keep = switch (after) {
        .ok => (pool.state == .ready or pool.state == .closing) and entry.generation == pool.generation,
        .broken => false,
        .clear => keep: {
            cleared = pool.clear(io, entry.generation, &dead);
            break :keep false;
        },
    };
    if (keep) {
        entry.idle_since = time.now(io);
        pool.idle.append(&entry.node);
        pool.idle_count += 1;
    } else {
        dead.append(&entry.node);
    }
    pool.passTurn(io);
    const generation = pool.generation;
    pool.mutex.unlock(io);
    bury(&dead);
    if (cleared) logClear(pool.options.server, generation, after.clear);
}

/// Refuses new calls and those in line (`error.Closed`) and stops the
/// openings; gives the exchanges in progress `timeout` to end, then cuts
/// them, and returns once every call has left and every connection is
/// closed: `drain`, then `finish`. The task's cancelation waits until it
/// returns. A second call, at once or later, returns once the first is
/// done.
pub fn close(pool: *Pool, io: Io, timeout: Io.Duration) void {
    if (pool.drain(io, timeout)) pool.finish(io);
}

/// The first step of `close`: refuses new calls and those in line
/// (`error.Closed`) and stops the openings; gives the exchanges in
/// progress `timeout` to end, then cuts them, and returns once every call
/// has left. The idle connections stay open until `finish`. True for the
/// call that closes the pool, which calls `finish`; a later one returns
/// false once that `finish` is done. The task's cancelation waits until
/// it returns.
pub fn drain(pool: *Pool, io: Io, timeout: Io.Duration) bool {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    pool.mutex.lockUncancelable(io);
    switch (pool.state) {
        .closed => {
            pool.mutex.unlock(io);
            return false;
        },
        .closing => {
            pool.mutex.unlock(io);
            pool.closed.waitUncancelable(io);
            return false;
        },
        .initialized, .ready, .paused => {},
    }
    pool.state = .closing;
    pool.wakeAll(io);
    var opening = pool.opening.first;
    while (opening) |node| : (opening = node.next) openingOf(node).attempt.stop(io);
    pool.signalDrained(io);
    pool.mutex.unlock(io);

    const until: core.Deadline = .after(time.now(io), timeout);
    while (!pool.drained.isSet() and !time.expired(io, until)) {
        pool.drained.waitTimeout(io, time.step(io, until).toTimeout()) catch {};
    }
    if (!pool.drained.isSet()) {
        pool.mutex.lockUncancelable(io);
        var in_use = pool.in_use.first;
        while (in_use) |node| : (in_use = node.next) {
            const entry = entryOf(node);
            entry.hooks.cut(entry, io);
        }
        pool.mutex.unlock(io);
        pool.drained.waitUncancelable(io);
    }
    return true;
}

/// The last step of `close`, after `drain`: closes the idle connections,
/// and the pool is closed.
pub fn finish(pool: *Pool, io: Io) void {
    var dead: List = .{};
    pool.mutex.lockUncancelable(io);
    std.debug.assert(pool.state == .closing);
    dead.concatByMoving(&pool.idle);
    pool.idle_count = 0;
    pool.state = .closed;
    pool.mutex.unlock(io);
    bury(&dead);
    pool.closed.set(io);
}

pub fn counts(pool: *Pool, io: Io) Counts {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    return .{
        .idle = pool.idle_count,
        .in_use = pool.in_use_count,
        .opening = pool.opening_count,
        .waiting = pool.waiting,
        .generation = pool.generation,
        .clears = pool.clears,
    };
}

/// A call in line.
const Waiter = struct {
    node: List.Node = .{},
    /// Set when it may look again: its turn, or the pool changed.
    turn: Io.Event = .unset,
};

/// An opening in progress, on the stack of the call that opens.
const Opening = struct {
    node: List.Node = .{},
    attempt: Attempt = .{},
};

fn openingOf(node: *List.Node) *Opening {
    return @fieldParentPtr("node", node);
}

fn entryOf(node: *List.Node) *Entry {
    return @alignCast(@fieldParentPtr("node", node));
}

const Purpose = enum {
    /// A call, which needs a client that `connect` made ready.
    call,
    /// The client's `connect`.
    connect,
};

/// What the first in line found: an idle connection, now in use, or a
/// place to open one, in which the call's opening is counted.
const Found = union(enum) {
    idle: Idle,
    open: Place,
};

const Idle = struct {
    entry: *Entry,
    /// It lay idle long enough to need PING first.
    check: bool,
};

const Place = struct {
    /// The generation the new connection belongs to.
    generation: u64,
    /// The opening is the probe of a paused pool.
    probe: bool = false,
};

fn take(pool: *Pool, io: Io, opener: Opener, deadline: ?core.Deadline, purpose: Purpose, d: ?*Diagnostics) Error!*Entry {
    // Back after a connection that failed its check.
    var again = false;
    while (true) {
        var dead: List = .{};
        var opening: Opening = .{};
        pool.mutex.lockUncancelable(io);
        const found = pool.wait(io, deadline, purpose, again, &opening, &dead, d);
        pool.mutex.unlock(io);
        bury(&dead);
        const place = switch (try found) {
            .idle => |idle| {
                if (!idle.check) return idle.entry;
                switch (idle.entry.hooks.ping(idle.entry, io, deadline)) {
                    .alive => return idle.entry,
                    .dead => {
                        log.debug("an idle connection to {f} failed its PING; it closes, and the call takes another", .{pool.options.server});
                        pool.checkIn(io, idle.entry, .broken);
                        again = true;
                        continue;
                    },
                    .deadline => {
                        pool.checkIn(io, idle.entry, .broken);
                        return fail(d, .checkout, error.DeadlineExceeded, "the deadline passed while PING checked a connection that had idled", .{});
                    },
                    .canceled => {
                        pool.checkIn(io, idle.entry, .broken);
                        return fail(d, .checkout, error.Cancelled, "the task was canceled while PING checked a connection that had idled", .{});
                    },
                }
            },
            .open => |place| place,
        };
        const result = opener.open(opener.context, io, deadline, &opening.attempt, d);
        return pool.opened(io, &opening, place, result, d);
    }
}

/// Waits in line, under the lock, which it lets go while it sleeps. A call
/// back `again` after a connection that failed its check goes first.
fn wait(pool: *Pool, io: Io, deadline: ?core.Deadline, purpose: Purpose, again: bool, opening: *Opening, dead: *List, d: ?*Diagnostics) Error!Found {
    switch (pool.state) {
        .initialized => if (purpose == .call) return fail(d, .checkout, error.Unavailable, "connect() has not succeeded", .{}),
        .ready => {},
        .paused => return pool.probe(io, opening, d),
        .closing, .closed => return fail(d, .checkout, error.Closed, "the client is closed", .{}),
    }
    // Nobody in line: no need to queue.
    if (pool.line.first == null) if (pool.find(io, opening, dead)) |found| return found;
    var waiter: Waiter = .{};
    if (again) pool.line.prepend(&waiter.node) else pool.line.append(&waiter.node);
    pool.waiting += 1;
    defer {
        pool.line.remove(&waiter.node);
        pool.waiting -= 1;
        // The next in line may go, when there is something for it.
        pool.passTurn(io);
    }
    while (true) {
        switch (pool.state) {
            .initialized, .ready => {},
            .paused => return fail(d, .checkout, error.Unavailable, "the pool was cleared while the call waited for a connection", .{}),
            .closing, .closed => return fail(d, .checkout, error.Closed, "the client was closed while the call waited for a connection", .{}),
        }
        if (pool.line.first == &waiter.node) if (pool.find(io, opening, dead)) |found| return found;
        if (deadline) |limit| if (time.expired(io, limit)) {
            return fail(d, .checkout, error.PoolExhausted, "the deadline passed while the call waited for a connection", .{});
        };
        // Only this call waits on its event, and others set it under the
        // mutex: resetting it here loses no wake.
        waiter.turn.reset();
        pool.mutex.unlock(io);
        const woken = waiter.turn.waitTimeout(io, time.step(io, deadline).toTimeout());
        pool.mutex.lockUncancelable(io);
        woken catch |err| switch (err) {
            // The deadline, a step of a far one or of none, or a spurious
            // wakeup: the loop looks again.
            error.Timeout => {},
            error.Canceled => {
                io.recancel();
                return fail(d, .checkout, error.Cancelled, "the task was canceled while it waited for a connection", .{});
            },
        };
    }
}

/// For the first in line: an idle connection, the one checked in last
/// first, else a place to open one; stale idle ones go to `dead`.
fn find(pool: *Pool, io: Io, opening: *Opening, dead: *List) ?Found {
    const now = time.now(io);
    while (pool.idle.popLast()) |node| {
        pool.idle_count -= 1;
        const entry = entryOf(node);
        if (entry.generation != pool.generation) {
            dead.append(node);
            continue;
        }
        pool.in_use.append(node);
        pool.in_use_count += 1;
        const idled = entry.idle_since.durationTo(now);
        return .{ .idle = .{ .entry = entry, .check = idled.nanoseconds >= pool.options.idle_check.nanoseconds } };
    }
    if (!pool.roomToOpen()) return null;
    pool.opening.append(&opening.node);
    pool.opening_count += 1;
    return .{ .open = .{ .generation = pool.generation } };
}

/// A call to a paused pool: the probe, which opens a connection, when no
/// probe is opening one, the last began 500 ms ago or more, and there is
/// room; else `error.Unavailable` at once.
fn probe(pool: *Pool, io: Io, opening: *Opening, d: ?*Diagnostics) Error!Found {
    if (pool.probing) return fail(d, .checkout, error.Unavailable, "the pool is paused after a clear, and a probe is opening a connection", .{});
    const now = time.now(io);
    if (pool.last_probe) |last| {
        const left = probe_interval.nanoseconds - last.durationTo(now).nanoseconds;
        if (left > 0) return fail(d, .checkout, error.Unavailable, "the pool is paused after a clear; the next probe may open a connection in {d} ms", .{
            @divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms),
        });
    }
    if (!pool.roomToOpen()) return fail(d, .checkout, error.Unavailable, "the pool is paused after a clear, and the connections before it fill it", .{});
    pool.probing = true;
    pool.last_probe = now;
    pool.opening.append(&opening.node);
    pool.opening_count += 1;
    return .{ .open = .{ .generation = pool.generation, .probe = true } };
}

/// What an opening ended with: the new connection, in use by the call
/// that opened it, or the error. A server that refuses the user clears the
/// pool; a probe that succeeds makes it ready again.
fn opened(pool: *Pool, io: Io, opening: *Opening, place: Place, result: Error!*Entry, d: ?*Diagnostics) Error!*Entry {
    var dead: List = .{};
    var cleared = false;
    pool.mutex.lockUncancelable(io);
    defer {
        // A place to open, or an opening less: the next in line may go.
        pool.passTurn(io);
        const generation = pool.generation;
        pool.mutex.unlock(io);
        bury(&dead);
        if (cleared) logClear(pool.options.server, generation, "the server refused the user");
    }
    pool.opening.remove(&opening.node);
    pool.opening_count -= 1;
    if (place.probe) pool.probing = false;
    const entry = result catch |err| {
        // The server refuses the user of every connection alike.
        if (err == error.AuthenticationFailed) cleared = pool.clear(io, place.generation, &dead);
        return err;
    };
    entry.generation = place.generation;
    switch (pool.state) {
        .closing, .closed => {
            dead.append(&entry.node);
            return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
        },
        // A clear pauses the pool only from ready, and the generation
        // stays while it is paused: the probe's connection is current.
        .paused => if (place.probe) {
            pool.state = .ready;
        },
        .initialized, .ready => {},
    }
    pool.in_use.append(&entry.node);
    pool.in_use_count += 1;
    return entry;
}

/// Clears the pool, under the lock: a new generation, the idle
/// connections to `dead`, the pool paused and the calls in line sent away.
/// False, and nothing changes, when the pool is not ready or `generation`
/// is older than the pool's: the error is stale, or cleared already.
fn clear(pool: *Pool, io: Io, generation: u64, dead: *List) bool {
    if (pool.state != .ready or generation != pool.generation) return false;
    pool.generation += 1;
    pool.clears += 1;
    pool.state = .paused;
    dead.concatByMoving(&pool.idle);
    pool.idle_count = 0;
    pool.wakeAll(io);
    return true;
}

fn logClear(server: Address, generation: u64, reason: []const u8) void {
    log.warn("the pool of connections to {f} is cleared: {s}; generation {d} begins, and calls get error.Unavailable until a new connection opens", .{ server, reason, generation });
}

fn total(pool: *const Pool) usize {
    return pool.idle_count + pool.in_use_count + pool.opening_count;
}

fn roomToOpen(pool: *const Pool) bool {
    return pool.total() < pool.options.max_size and pool.opening_count < pool.options.max_connecting;
}

/// Wakes the first in line when there is something for it.
fn passTurn(pool: *Pool, io: Io) void {
    const first = pool.line.first orelse return;
    if (pool.idle_count == 0 and !pool.roomToOpen()) return;
    const waiter: *Waiter = @fieldParentPtr("node", first);
    waiter.turn.set(io);
}

/// Wakes every call in line, to see that the pool changed.
fn wakeAll(pool: *Pool, io: Io) void {
    var it = pool.line.first;
    while (it) |node| : (it = node.next) {
        const waiter: *Waiter = @fieldParentPtr("node", node);
        waiter.turn.set(io);
    }
}

fn signalDrained(pool: *Pool, io: Io) void {
    if (pool.state == .closing and pool.calls == 0) pool.drained.set(io);
}

/// Closes the connections of `dead`, outside the lock.
fn bury(dead: *List) void {
    while (dead.popFirst()) |node| {
        const entry = entryOf(node);
        entry.hooks.destroy(entry);
    }
}

fn fail(d: ?*Diagnostics, phase: Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
