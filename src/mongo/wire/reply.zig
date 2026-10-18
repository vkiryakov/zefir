//! The `ok` of a reply, as every driver maps it to the contract's errors.

const std = @import("std");
const bson = @import("../bson.zig");
const errors = @import("../contract/errors.zig");
const Diagnostics = errors.Diagnostics;

/// Checks the `ok` of a command's reply: 1 passes, any other number is the
/// server's failure. That is `error.CommandFailed`, or `error.Timeout` for
/// code 50 (MaxTimeMSExpired), with the server's error and errmsg in
/// `diagnostics` and the whole reply copied into `failure_reply`, from
/// `allocator`; the slot must hold null. A reply without a numeric `ok` is
/// `error.ProtocolViolation`.
pub fn checkReply(reply: bson.RawDocument, allocator: std.mem.Allocator, diagnostics: ?*Diagnostics, failure_reply: ?*?bson.OwnedDocument) errors.Error!void {
    const ok = (reply.get("ok") catch null) orelse {
        if (diagnostics) |d| d.set(.receive, null, "the reply has no ok", .{});
        return error.ProtocolViolation;
    };
    const value = ok.asF64() catch {
        if (diagnostics) |d| d.set(.receive, null, "ok of the reply is not a number", .{});
        return error.ProtocolViolation;
    };
    if (value == 1) return;
    if (failure_reply) |slot| slot.* = try reply.dupe(allocator);
    if (diagnostics) |d| d.setServer(.receive, reply);
    return if (errors.ServerError.fromReply(reply).code == 50) error.Timeout else error.CommandFailed;
}

const testing = std.testing;

test "ok 1 passes, as a double, an int32 or an int64" {
    for ([_]bson.RawDocument{ bson.literal(.{ .ok = 1.0 }), bson.literal(.{ .n = 2, .ok = 1 }), bson.literal(.{ .ok = @as(i64, 1) }) }) |reply| {
        try checkReply(reply, testing.allocator, null, null);
    }
}

test "ok 0 is CommandFailed with the server's error, and code 50 is Timeout" {
    const reply = bson.literal(.{ .ok = 0.0, .errmsg = "no such command: 'nope'", .code = 59, .codeName = "CommandNotFound" });
    var d: Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, checkReply(reply, testing.allocator, &d, &failure));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, reply.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 59), d.server.?.code);
    try testing.expectEqualStrings("CommandNotFound", d.server.?.code_name.slice());
    try testing.expectEqualStrings("no such command: 'nope'", d.message());

    const expired = bson.literal(.{ .ok = 0, .errmsg = "operation exceeded time limit", .code = 50, .codeName = "MaxTimeMSExpired" });
    try testing.expectError(error.Timeout, checkReply(expired, testing.allocator, &d, null));
    try testing.expectEqual(@as(i32, 50), d.server.?.code);
}

test "a reply without a numeric ok is a protocol violation" {
    for ([_]bson.RawDocument{ bson.literal(.{ .n = 1 }), bson.literal(.{ .ok = "yes" }) }) |reply| {
        var d: Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, checkReply(reply, testing.allocator, &d, null));
        try testing.expect(std.mem.find(u8, d.message(), "ok") != null);
    }
}
