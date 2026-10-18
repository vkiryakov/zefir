//! What a failed exchange or a refusal of the server leaves of the pool.

const std = @import("std");
const mongo = @import("mongo");
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

/// What a reply leaves: ok 0 from a server shutting down clears the pool.
pub fn afterReply(reply: bson.RawDocument) Pool.After {
    const ok = if (reply.get("ok") catch null) |value| value.asF64() catch 0 else 0;
    if (ok == 1) return .ok;
    return switch (mongo.ServerError.fromReply(reply).code) {
        11600 => .{ .clear = "it answered InterruptedAtShutdown (11600)" },
        91 => .{ .clear = "it answered ShutdownInProgress (91)" },
        else => .ok,
    };
}

const testing = std.testing;

test "a reply clears the pool only with ok 0 and the codes of a server shutting down" {
    const cases = [_]struct { bson.RawDocument, bool }{
        .{ bson.literal(.{ .ok = 1.0 }), false },
        .{ bson.literal(.{ .ok = 0.0, .code = 59, .codeName = "CommandNotFound" }), false },
        .{ bson.literal(.{ .ok = 0.0, .code = 91, .codeName = "ShutdownInProgress" }), true },
        .{ bson.literal(.{ .ok = 0, .code = 11600, .codeName = "InterruptedAtShutdown" }), true },
        // A code of 91 next to ok 1 is no refusal.
        .{ bson.literal(.{ .ok = 1, .code = 91 }), false },
    };
    for (cases) |case| {
        const reply, const clears = case;
        try testing.expectEqual(clears, afterReply(reply) == .clear);
    }
}
