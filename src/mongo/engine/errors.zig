//! How the calls of the driver fail, where, and what each failure leaves
//! of the pool:
//!
//! | where | what happened | error | the pool |
//! |---|---|---|---|
//! | before sending | the deadline passed, or less than 1 ms beyond the shortest round trip is left | `DeadlineExceeded` | the connection goes back |
//! | checkout | the deadline or `serverSelectionTimeoutMS` ended in line | `PoolExhausted` | — |
//! | checkout | paused after a clear, a failed probe, no `connect` | `Unavailable` | — |
//! | opening | DNS, TCP, I/O of hello | `Unavailable`, with the labels of overload unless DNS failed | not cleared |
//! | opening | the deadline of the call | `DeadlineExceeded` | — |
//! | opening | the server's type or version, SCRAM-SHA-256 with a password that is not ASCII | `Unsupported` | — |
//! | opening | SCRAM: codes 18 and 334, the nonce, the iterations, the signature | `AuthenticationFailed` | cleared |
//! | exchange | the end of the stream or a reset after the command started out | `ConnectionLost` | cleared |
//! | exchange | the deadline while writing or reading | `Timeout` | the connection closes |
//! | exchange | the task canceled | `Interrupted` | the connection closes |
//! | reply | it breaks OP_MSG | `ProtocolViolation` | the connection closes |
//! | reply | ok 0 | `CommandFailed`, code 50 `Timeout` | cleared by 11600 and 91 |
//! | reply | ok 1, a writeConcernError of 11600 or 91 | none: the reply, or the write result, holds it | cleared |
//! | after `close` | — | `Closed` | — |
//!
//! Code 50, MaxTimeMSExpired, is `Timeout` wherever it comes: in a reply
//! with ok 0, which `wire.checkReply` reads, and among the
//! `writeErrors` or in the `writeConcernError` of a write, which
//! `wire.batch.Merge` reads. The whole reply of a failure goes to
//! `failure_reply` from the call's allocator, and for `openCursor` from the
//! client's, as the cursor's replies do; a cursor keeps the reply of its
//! refused `getMore` itself, with the diagnostics of the error.
//!
//! A canceled task sees `error.Canceled` of std once: the driver cancels
//! the task again (`io.recancel()`) and returns `Cancelled` before its
//! command went out and `Interrupted` after, so that the task keeps its
//! cancelation.

const std = @import("std");
const Io = std.Io;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const Connection = @import("Connection.zig");
const Pool = @import("Pool.zig");

/// What an exchange that failed leaves of its connection: a network error
/// on it clears the pool, since the others are likely gone too; a cut is
/// `close`'s; a timeout, a cancelation or a broken reply close only it.
pub fn afterExchange(conn: *Connection, err: mongo.Error, d: ?*Diagnostics) Pool.After {
    if (err != error.ConnectionLost) return if (conn.usable) .ok else .broken;
    const cause = conn.stream.err orelse return .{ .clear = "a connection to it broke" };
    if (cause != error.Stopped) return .{ .clear = "a connection to it broke" };
    // The phase stays: the cut may come while the command goes out.
    if (d) |x| x.set(x.phase, null, "close() of the client cut the exchange", .{});
    return .broken;
}

/// The error of a call whose task was canceled, which stays canceled:
/// `Cancelled` before its command went out, `Interrupted` after.
pub fn canceled(io: Io, d: ?*Diagnostics, phase: Diagnostics.Phase, sent: bool, comptime text: []const u8) mongo.Error {
    io.recancel();
    if (d) |x| x.set(phase, null, text, .{});
    return if (sent) error.Interrupted else error.Cancelled;
}

/// What a reply leaves: a server shutting down clears the pool, whether it
/// says so with ok 0 or, as SDAM reads a reply too, in the
/// `writeConcernError` of a write it did.
pub fn afterReply(reply: bson.RawDocument) Pool.After {
    const ok = if (reply.get("ok") catch null) |value| value.asF64() catch 0 else 0;
    if (ok != 1) return switch (mongo.ServerError.fromReply(reply).code) {
        11600 => .{ .clear = "it answered InterruptedAtShutdown (11600)" },
        91 => .{ .clear = "it answered ShutdownInProgress (91)" },
        else => .ok,
    };
    const concern = (reply.get("writeConcernError") catch null) orelse return .ok;
    if (concern != .document) return .ok;
    return switch (mongo.ServerError.fromReply(concern.document).code) {
        11600 => .{ .clear = "it answered InterruptedAtShutdown (11600) in a writeConcernError" },
        91 => .{ .clear = "it answered ShutdownInProgress (91) in a writeConcernError" },
        else => .ok,
    };
}

const testing = std.testing;

test "a reply clears the pool only with the codes of a server shutting down: with ok 0, or in a writeConcernError" {
    const cases = [_]struct { bson.RawDocument, bool }{
        .{ bson.literal(.{ .ok = 1.0 }), false },
        .{ bson.literal(.{ .ok = 0.0, .code = 59, .codeName = "CommandNotFound" }), false },
        .{ bson.literal(.{ .ok = 0.0, .code = 91, .codeName = "ShutdownInProgress" }), true },
        .{ bson.literal(.{ .ok = 0, .code = 11600, .codeName = "InterruptedAtShutdown" }), true },
        // A code of 91 next to ok 1 is no refusal.
        .{ bson.literal(.{ .ok = 1, .code = 91 }), false },
        // A write done, whose write concern the server shutting down left
        // unsatisfied: SDAM reads the writeConcernError as a refusal.
        .{ bson.literal(.{ .n = 1, .writeConcernError = .{ .code = 91, .codeName = "ShutdownInProgress", .errmsg = "the server is shutting down" }, .ok = 1.0 }), true },
        .{ bson.literal(.{ .n = 1, .writeConcernError = .{ .code = 11600, .codeName = "InterruptedAtShutdown", .errmsg = "interrupted at shutdown" }, .ok = 1.0 }), true },
        .{ bson.literal(.{ .n = 1, .writeConcernError = .{ .code = 64, .codeName = "WriteConcernFailed", .errmsg = "waiting for replication timed out" }, .ok = 1.0 }), false },
        .{ bson.literal(.{ .n = 1, .writeConcernError = "not a document", .ok = 1.0 }), false },
    };
    for (cases) |case| {
        const reply, const clears = case;
        try testing.expectEqual(clears, afterReply(reply) == .clear);
    }
}
