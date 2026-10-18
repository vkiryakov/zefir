//! The connections to the server, pooled as CMAP, the Connection
//! Monitoring and Pooling specification of MongoDB, pools them for one
//! endpoint. A call takes a connection for one exchange (`checkOut`) and
//! gives it back (`checkIn`).
//!
//! - At most `max_size` connections (maxPoolSize), of which at most
//!   `max_connecting` are being opened at once (maxConnecting); an idle
//!   one is kept for `max_idle_time` (maxIdleTimeMS), for good when that
//!   is null. Connections open only when calls need them: minPoolSize is
//!   0, and nothing runs in the background.
//! - A call that finds no connection waits in line, first come first
//!   served, until its budget ends (`error.PoolExhausted`) or its task is
//!   canceled (`error.Cancelled`); one that leaves passes its turn on.
//! - A call opens a connection outside the lock and gets the one it
//!   opened, so that opening one never holds up the calls that find an
//!   idle one. An opening that fails or is canceled frees its place.
//! - A connection is perished when it is of an older generation, idle for
//!   longer than `max_idle_time`, or left broken by its exchange: it
//!   closes at check-out or at check-in.
//! - `close` refuses new calls and those in line (`error.Closed`), stops
//!   the openings, lets the exchanges in progress end within its time,
//!   then cuts them.
//!
//! A connection holds its `Entry`, the pool's part of it, as a field; the
//! pool opens connections through the caller's `Opener`, so that tests
//! run it on connections of their own.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const mongo = @import("mongo");
const Diagnostics = mongo.Diagnostics;
const Address = @import("Connection.zig").Address;
const Attempt = @import("connect.zig").Attempt;
const time = @import("time.zig");
const Pool = @This();
const List = std.DoublyLinkedList;

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
/// Set once the pool is closing and no call is left.
drained: Io.Event = .unset,
/// Set once `close` is done.
closed: Io.Event = .unset,

pub const Options = struct {
    /// The server, for messages.
    server: Address,
    max_size: u32 = 100,
    max_connecting: u32 = 2,
    /// Null: an idle connection stays.
    max_idle_time: ?Io.Duration = null,
};

pub const State = enum { initialized, ready, closing, closed };

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
    };
};

/// How a call opens a connection: `open` returns the entry of the new
/// connection, or the contract's error for the call. A canceled task gives
/// `error.Cancelled`, and stays canceled; an attempt that `close` stopped
/// gives `error.Closed`.
pub const Opener = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, io: Io, limits: Limits, attempt: *Attempt, d: ?*Diagnostics) mongo.Error!*Entry,
};

/// The budget of a call: its deadline, and the end of
/// serverSelectionTimeoutMS from its start, which bounds the wait for a
/// connection and its opening.
pub const Limits = struct {
    deadline: ?core.Deadline = null,
    checkout: core.Deadline,

    /// The end of the wait in line: the earlier of the two.
    pub fn wait(l: Limits) core.Deadline {
        const deadline = l.deadline orelse return l.checkout;
        return deadline.earliest(l.checkout);
    }

    /// Whether the call's deadline, and not serverSelectionTimeoutMS,
    /// ends the wait.
    pub fn byDeadline(l: Limits) bool {
        const deadline = l.deadline orelse return false;
        return deadline.expires.nanoseconds <= l.checkout.expires.nanoseconds;
    }
};

/// What an exchange left of the connection that `checkIn` takes back.
pub const After = union(enum) {
    /// It is as it was.
    ok,
    /// It is broken: close it.
    broken,
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
pub fn enter(pool: *Pool, io: Io, d: ?*Diagnostics) mongo.Error!void {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    switch (pool.state) {
        .closing, .closed => return fail(d, .checkout, error.Closed, "the client is closed", .{}),
        .initialized, .ready => {},
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
    return pool.state == .ready;
}

/// Opens the first connection, for the client's `connect`, which calls
/// may not do before: the pool is ready from then on, and keeps the
/// connection idle.
pub fn connect(pool: *Pool, io: Io, opener: Opener, limits: Limits, d: ?*Diagnostics) mongo.Error!void {
    const entry = try pool.take(io, opener, limits, .connect, d);
    pool.mutex.lockUncancelable(io);
    const closing = pool.state == .closing or pool.state == .closed;
    if (pool.state == .initialized) pool.state = .ready;
    pool.mutex.unlock(io);
    pool.checkIn(io, entry, .ok);
    if (closing) return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
}

/// A connection for one exchange: an idle one, or one the call opens,
/// waiting in line when there is neither. Give it back with `checkIn`.
pub fn checkOut(pool: *Pool, io: Io, opener: Opener, limits: Limits, d: ?*Diagnostics) mongo.Error!*Entry {
    return pool.take(io, opener, limits, .call, d);
}

/// Takes `entry` back: idle, or closed when it is perished or the pool is
/// closing.
pub fn checkIn(pool: *Pool, io: Io, entry: *Entry, after: After) void {
    var dead: List = .{};
    pool.mutex.lockUncancelable(io);
    pool.in_use.remove(&entry.node);
    pool.in_use_count -= 1;
    const keep = switch (after) {
        .ok => pool.state == .ready and entry.generation == pool.generation,
        .broken => false,
    };
    if (keep) {
        entry.idle_since = time.now(io);
        pool.idle.append(&entry.node);
        pool.idle_count += 1;
    } else {
        dead.append(&entry.node);
    }
    pool.passTurn(io);
    pool.mutex.unlock(io);
    bury(&dead);
}

/// Refuses new calls and those in line (`error.Closed`) and stops the
/// openings; gives the exchanges in progress `timeout` to end, then cuts
/// them, and returns once every call has left and every connection is
/// closed. The task's cancelation waits until it returns. A second call,
/// at once or later, returns once the first is done.
pub fn close(pool: *Pool, io: Io, timeout: Io.Duration) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var dead: List = .{};
    pool.mutex.lockUncancelable(io);
    switch (pool.state) {
        .closed => {
            pool.mutex.unlock(io);
            return;
        },
        .closing => {
            pool.mutex.unlock(io);
            pool.closed.waitUncancelable(io);
            return;
        },
        .initialized, .ready => {},
    }
    pool.state = .closing;
    pool.wakeAll(io);
    var opening = pool.opening.first;
    while (opening) |node| : (opening = node.next) openingOf(node).attempt.stop(io);
    dead.concatByMoving(&pool.idle);
    pool.idle_count = 0;
    pool.signalDrained(io);
    pool.mutex.unlock(io);
    bury(&dead);

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
    pool.mutex.lockUncancelable(io);
    pool.state = .closed;
    pool.mutex.unlock(io);
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
    /// Set when it may look again: its turn, or the pool closing.
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
    /// An operation, which needs a client that `connect` made ready.
    call,
    /// The client's `connect`.
    connect,
};

/// What the first in line found: an idle connection, now in use, or a
/// place to open one, in which the call's opening is counted.
const Found = union(enum) {
    entry: *Entry,
    open: Place,
};

const Place = struct {
    /// The generation the new connection belongs to.
    generation: u64,
};

fn take(pool: *Pool, io: Io, opener: Opener, limits: Limits, purpose: Purpose, d: ?*Diagnostics) mongo.Error!*Entry {
    var dead: List = .{};
    var opening: Opening = .{};
    pool.mutex.lockUncancelable(io);
    const found = pool.wait(io, limits, purpose, &opening, &dead, d);
    pool.mutex.unlock(io);
    bury(&dead);
    const place = switch (try found) {
        .entry => |entry| return entry,
        .open => |place| place,
    };
    const result = opener.open(opener.context, io, limits, &opening.attempt, d);
    return pool.opened(io, &opening, place, result, d);
}

/// Waits in line, under the lock, which it lets go while it sleeps.
fn wait(pool: *Pool, io: Io, limits: Limits, purpose: Purpose, opening: *Opening, dead: *List, d: ?*Diagnostics) mongo.Error!Found {
    switch (pool.state) {
        .initialized => if (purpose == .call) return fail(d, .checkout, error.Unavailable, "connect() has not succeeded", .{}),
        .ready => {},
        .closing, .closed => return fail(d, .checkout, error.Closed, "the client is closed", .{}),
    }
    // Nobody in line: no need to queue.
    if (pool.line.first == null) if (pool.find(io, opening, dead)) |found| return found;
    var waiter: Waiter = .{};
    pool.line.append(&waiter.node);
    pool.waiting += 1;
    defer {
        pool.line.remove(&waiter.node);
        pool.waiting -= 1;
        // The next in line may go, when there is something for it.
        pool.passTurn(io);
    }
    const until = limits.wait();
    while (true) {
        switch (pool.state) {
            .initialized, .ready => {},
            .closing, .closed => return fail(d, .checkout, error.Closed, "the client was closed while the call waited for a connection", .{}),
        }
        if (pool.line.first == &waiter.node) if (pool.find(io, opening, dead)) |found| return found;
        if (time.expired(io, until)) {
            if (limits.byDeadline()) return fail(d, .checkout, error.PoolExhausted, "the deadline passed while the call waited for a connection", .{});
            return fail(d, .checkout, error.PoolExhausted, "serverSelectionTimeoutMS passed while the call waited for a connection", .{});
        }
        // Only this call waits on its event, and others set it under the
        // mutex: resetting it here loses no wake.
        waiter.turn.reset();
        pool.mutex.unlock(io);
        const woken = waiter.turn.waitTimeout(io, time.step(io, until).toTimeout());
        pool.mutex.lockUncancelable(io);
        woken catch |err| switch (err) {
            // The budget, a step of a far one, or a spurious wakeup: the
            // loop looks again.
            error.Timeout => {},
            error.Canceled => {
                io.recancel();
                return fail(d, .checkout, error.Cancelled, "the task was canceled while it waited for a connection", .{});
            },
        };
    }
}

/// For the first in line: an idle connection, the one checked in last
/// first, else a place to open one; perished idle ones go to `dead`.
fn find(pool: *Pool, io: Io, opening: *Opening, dead: *List) ?Found {
    const now = time.now(io);
    while (pool.idle.popLast()) |node| {
        pool.idle_count -= 1;
        const entry = entryOf(node);
        if (pool.perished(entry, now)) {
            dead.append(node);
            continue;
        }
        pool.in_use.append(node);
        pool.in_use_count += 1;
        return .{ .entry = entry };
    }
    if (!pool.roomToOpen()) return null;
    pool.opening.append(&opening.node);
    pool.opening_count += 1;
    return .{ .open = .{ .generation = pool.generation } };
}

/// What an opening ended with, under the lock: the new connection, in use
/// by the call that opened it, or the error.
fn opened(pool: *Pool, io: Io, opening: *Opening, place: Place, result: mongo.Error!*Entry, d: ?*Diagnostics) mongo.Error!*Entry {
    var dead: List = .{};
    pool.mutex.lockUncancelable(io);
    defer {
        // A place to open, or an opening less: the next in line may go.
        pool.passTurn(io);
        pool.mutex.unlock(io);
        bury(&dead);
    }
    pool.opening.remove(&opening.node);
    pool.opening_count -= 1;
    const entry = try result;
    entry.generation = place.generation;
    switch (pool.state) {
        .closing, .closed => {
            dead.append(&entry.node);
            return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
        },
        .initialized, .ready => {},
    }
    pool.in_use.append(&entry.node);
    pool.in_use_count += 1;
    return entry;
}

fn perished(pool: *const Pool, entry: *const Entry, now: Io.Timestamp) bool {
    if (entry.generation != pool.generation) return true;
    const max = pool.options.max_idle_time orelse return false;
    return entry.idle_since.durationTo(now).nanoseconds >= max.nanoseconds;
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

fn fail(d: ?*Diagnostics, phase: Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
