//! One command of a call, on a connection of the pool, by the rules of the
//! contract and of CSOT:
//!
//! - The deadline of a call is its context's, else `timeoutMS` from the
//!   start of the call, else there is none.
//! - The connection comes from the pool within the deadline and
//!   `serverSelectionTimeoutMS`, opened if need be.
//! - Then the command takes `maxTimeMS`: the time left less the shortest
//!   round trip of hello, in whole milliseconds. `getMore` and
//!   `killCursors` take none. With less than 1 ms of it left, the command
//!   does not go out: `error.DeadlineExceeded`, and the connection goes
//!   back to the pool.
//! - Of the driver's fields a command carries `$db` always, `maxTimeMS`
//!   by the rule above, and nothing else.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const opmsg = wire.opmsg;
const Diagnostics = mongo.Diagnostics;
const OperationContext = mongo.OperationContext;
const Connection = @import("Connection.zig");
const Pool = @import("Pool.zig");
const cursor = @import("cursor.zig");
const errors = @import("errors.zig");
const time = @import("time.zig");

/// What the operations need of their client: its pool and how the pool
/// opens connections, its timeouts, the round trips of its connections
/// and its cursors. The client hands one out for each call; it points
/// into the client, which stays where `connect` ran.
pub const Runner = struct {
    /// The `io` of `Client.init`: every call comes on it.
    io: Io,
    /// The client's memory, which its cursors hold their batches in.
    gpa: Allocator,
    pool: *Pool,
    opener: Pool.Opener,
    round_trips: *time.RoundTrips,
    cursors: *cursor.Registry,
    /// `timeoutMS`: the deadline of a call whose context has none.
    timeout: ?Io.Duration,
    server_selection_timeout: Io.Duration,
    /// The budget of the `killCursors` that closing a cursor sends.
    cursor_close_timeout: Io.Duration,

    /// In safe builds: a call on another `std.Io` than the client's
    /// panics, since the waits of the client belong to its own.
    pub fn checkIo(r: Runner, io: Io) void {
        if (std.debug.runtime_safety and io.vtable != r.io.vtable) {
            @panic("zefir-mongo-async-driver: a call on another std.Io than the client's: pass the io of Client.init");
        }
    }

    /// The deadline of a call that starts now: its context's, else
    /// `timeoutMS` from now.
    pub fn deadlineOf(r: Runner, io: Io, op: OperationContext) ?core.Deadline {
        if (op.ctx.deadline) |deadline| return deadline;
        const timeout = r.timeout orelse return null;
        return .after(time.now(io), timeout);
    }

    /// The budget of a checkout that starts now under `deadline`.
    pub fn limits(r: Runner, io: Io, deadline: ?core.Deadline) Pool.Limits {
        return .{ .deadline = deadline, .checkout = .after(time.now(io), r.server_selection_timeout) };
    }
};

/// A command as a call sends it; `$db` and, under a deadline, `maxTimeMS`
/// go with it.
pub const Request = struct {
    database: []const u8,
    body: bson.RawDocument,
    /// `ordered`, for a write.
    ordered: ?bool = null,
    /// The items of a write.
    sequence: ?opmsg.Sequence = null,
};

/// `runCommand`: the reply to `command`, from `options.allocator`, whose
/// `ok` is 1.
pub fn run(r: Runner, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
    const d = options.diagnostics;
    try r.pool.enter(io, d);
    defer r.pool.leave(io);
    const reply = try send(r, io, op, r.deadlineOf(io, op), .{ .database = command.database, .body = command.body }, options.allocator, d);
    wire.checkReply(reply.raw(), options.allocator, d, options.failure_reply) catch |err| {
        reply.deinit();
        return err;
    };
    return reply;
}

/// Sends `request` on a connection of the pool under `deadline`, the
/// deadline of the whole call, and returns the reply, from `allocator`,
/// with its `ok` unchecked. The connection goes back to the pool, closes,
/// or clears the pool, as the exchange and the reply say. The caller has
/// entered the pool.
pub fn send(r: Runner, io: Io, op: OperationContext, deadline: ?core.Deadline, request: Request, allocator: Allocator, d: ?*Diagnostics) mongo.Error!bson.OwnedDocument {
    var taken = try take(r, io, op, deadline, request.body, d);
    defer give(r, io, &taken);
    return exchange(r, io, &taken, op, deadline, request, allocator, d);
}

/// A connection of the pool taken for one exchange, and what the exchange
/// left of it, which `give` hands back to the pool.
pub const Taken = struct {
    entry: *Pool.Entry,
    after: Pool.After = .ok,

    pub fn connection(t: *const Taken) *Connection {
        return Connection.of(t.entry);
    }
};

/// A connection for a command of `body` under `deadline`, within the
/// deadline and `serverSelectionTimeoutMS`. A call that cannot go out
/// takes none: less than 1 ms left of the deadline, a canceled token, or
/// `maxTimeMS` of the caller next to a deadline of `timeoutMS`, which the
/// contract leaves to the driver to see.
pub fn take(r: Runner, io: Io, op: OperationContext, deadline: ?core.Deadline, body: bson.RawDocument, d: ?*Diagnostics) mongo.Error!Taken {
    if (deadline) |dl| if (dl.remaining(time.now(io)).nanoseconds < std.time.ns_per_ms) {
        return fail(d, .checkout, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
    };
    if (op.ctx.isCancelled()) return fail(d, .checkout, error.Cancelled, "the token was canceled before the command went out", .{});
    if (deadline != null and op.ctx.deadline == null and hasMaxTime(body)) {
        return fail(d, null, error.InvalidArgument, "the command holds maxTimeMS and timeoutMS of the connection string gives the call a deadline, from which the driver writes maxTimeMS: drop one of the two", .{});
    }
    return .{ .entry = try r.pool.checkOut(io, r.opener, r.limits(io, deadline), d) };
}

/// Sends `request` on the connection of `taken` and returns the reply,
/// from `allocator`, with its `ok` unchecked; `taken` keeps what the
/// exchange and the reply leave of the connection.
pub fn exchange(r: Runner, io: Io, taken: *Taken, op: OperationContext, deadline: ?core.Deadline, request: Request, allocator: Allocator, d: ?*Diagnostics) mongo.Error!bson.OwnedDocument {
    const max_time_ms = try beforeSend(r, io, op, deadline, request.body, d);
    const conn = taken.connection();
    const reply = conn.exchange(.{
        .database = request.database,
        .body = request.body,
        .ordered = request.ordered,
        .max_time_ms = max_time_ms,
        .sequence = request.sequence,
    }, allocator, deadline, d) catch |err| {
        taken.after = errors.afterExchange(conn, err, d);
        return err;
    };
    taken.after = errors.afterReply(reply.raw());
    return reply;
}

/// Hands the connection of `taken` back to the pool.
pub fn give(r: Runner, io: Io, taken: *Taken) void {
    r.pool.checkIn(io, taken.entry, taken.after);
}

/// The checks of a command about to go out on its connection, and its
/// `maxTimeMS`: none without a deadline, nor for `getMore` and
/// `killCursors`. Less than 1 ms left of the deadline, beyond the
/// shortest round trip, is `DeadlineExceeded`; a token or a task canceled
/// meanwhile is `Cancelled`.
fn beforeSend(r: Runner, io: Io, op: OperationContext, deadline: ?core.Deadline, body: bson.RawDocument, d: ?*Diagnostics) mongo.Error!?i64 {
    var max_time_ms: ?i64 = null;
    if (deadline) |dl| {
        const min_rtt = r.round_trips.min(io);
        const ms = time.maxTimeMs(dl.remaining(time.now(io)), min_rtt) orelse {
            if (min_rtt.nanoseconds == 0) return fail(d, .send, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
            return fail(d, .send, error.DeadlineExceeded, "less than 1 ms beyond the shortest round trip to the server ({d} us) was left of the deadline before the command went out", .{min_rtt.toMicroseconds()});
        };
        if (takesMaxTime(body)) max_time_ms = ms;
    }
    if (op.ctx.isCancelled()) return fail(d, .send, error.Cancelled, "the token was canceled before the command went out", .{});
    io.checkCancel() catch return errors.canceled(io, d, .send, false, "the task was canceled before the command went out");
    return max_time_ms;
}

/// Whether `body` takes `maxTimeMS` under a deadline: every command but
/// `getMore` and `killCursors`, which mongod refuses it on.
fn takesMaxTime(body: bson.RawDocument) bool {
    const first = (body.first() catch null) orelse return true;
    return !std.mem.eql(u8, first.key, "getMore") and !std.mem.eql(u8, first.key, "killCursors");
}

fn hasMaxTime(body: bson.RawDocument) bool {
    var it = body.iterator();
    while (it.next() catch null) |element| {
        if (std.mem.eql(u8, element.key, "maxTimeMS")) return true;
    }
    return false;
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

const testing = std.testing;

test "getMore and killCursors take no maxTimeMS; every other command does" {
    try testing.expect(takesMaxTime(bson.literal(.{ .find = "users" })));
    try testing.expect(takesMaxTime(bson.literal(.{ .insert = "users" })));
    try testing.expect(!takesMaxTime(bson.literal(.{ .getMore = @as(i64, 7), .collection = "users" })));
    try testing.expect(!takesMaxTime(bson.literal(.{ .killCursors = "users", .cursors = .{@as(i64, 7)} })));
}
