//! Tests of the errors of the client: the class of every name, and what
//! `Diagnostics` and `ServerError` keep of long texts and of the labels.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const ServerError = errors.ServerError;
const Label = errors.Label;

test "every name of mongo.Error has the class of the design's table" {
    const table = [_]struct { []const u8, errors.Outcome }{
        .{ "InvalidArgument", .not_sent },
        .{ "Unsupported", .not_sent },
        .{ "Closed", .not_sent },
        .{ "Unavailable", .not_sent },
        .{ "AuthenticationFailed", .not_sent },
        .{ "PoolExhausted", .not_sent },
        .{ "DeadlineExceeded", .not_sent },
        .{ "Cancelled", .not_sent },
        .{ "ConnectionLost", .may_have_executed },
        .{ "Timeout", .may_have_executed },
        .{ "Interrupted", .may_have_executed },
        .{ "IncompleteWrite", .may_have_executed },
        .{ "ProtocolViolation", .may_have_executed },
        .{ "CommandFailed", .may_have_executed },
        .{ "WriteFailed", .may_have_executed },
        .{ "OutOfMemory", .may_have_executed },
    };
    const names = @typeInfo(errors.Error).error_set.error_names.?;
    try testing.expectEqual(table.len, names.len);
    inline for (names) |name| {
        const err = @field(errors.Error, name);
        const expected = for (table) |row| {
            if (std.mem.eql(u8, row[0], name)) break row[1];
        } else {
            std.debug.print("{s} is not in the table\n", .{name});
            return error.TestUnexpectedResult;
        };
        errdefer std.debug.print("error.{s}\n", .{name});
        try testing.expectEqual(expected, errors.outcome(err));
    }
}

test "a message longer than the buffer is cut before a character that does not fit whole" {
    var d: Diagnostics = .{};
    try testing.expectEqualStrings("", d.message());
    // 511 bytes, then "П" (2 bytes) across the end of the 512-byte buffer.
    const cut = @as([511]u8, @splat('a')) ++ "Привет".*;
    d.set(.receive, null, "{s}", .{&cut});
    try testing.expectEqualStrings(cut[0..511], d.message());
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));

    // A character that ends right at the end of the buffer stays.
    const exact = @as([510]u8, @splat('b')) ++ "Я".*;
    d.set(.receive, null, "{s}and more", .{&exact});
    try testing.expectEqualStrings(&exact, d.message());

    // Three bytes of a character of four fit: all three go.
    const four = @as([509]u8, @splat('c')) ++ "😀".*;
    d.set(.receive, null, "{s}", .{&four});
    try testing.expectEqualStrings(four[0..509], d.message());
}

test "bytes that are not UTF-8 become '?', so the message always is" {
    var d: Diagnostics = .{};
    d.set(null, null, "{s}", .{"a\xffb\xc3(c"});
    try testing.expectEqualStrings("a?b?(c", d.message());
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
}

test "set records the phase, the cause and the message, and a later set replaces them" {
    var d: Diagnostics = .{};
    d.set(.send, error.BrokenPipe, "wrote {d} of {d} bytes", .{ 12, 40 });
    try testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
    try testing.expectEqual(error.BrokenPipe, d.cause.?);
    try testing.expectEqualStrings("wrote 12 of 40 bytes", d.message());
    d.set(null, null, "the deadline has passed", .{});
    try testing.expectEqual(@as(?Diagnostics.Phase, null), d.phase);
    try testing.expectEqual(@as(?anyerror, null), d.cause);
    try testing.expectEqualStrings("the deadline has passed", d.message());
}

test "a reply with ok: 0 gives its code, codeName and labels, and errmsg as the message" {
    var long_errmsg: [600]u8 = undefined;
    // 511 bytes of 'x', then Cyrillic across the cut at 512.
    @memset(long_errmsg[0..511], 'x');
    @memcpy(long_errmsg[511..][0..12], "Привет");
    @memset(long_errmsg[523..], 'y');
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putDouble("ok", 0);
    try b.putString("errmsg", &long_errmsg);
    try b.putInt32("code", 462);
    try b.putString("codeName", "IngressRequestRateLimitExceeded");
    try b.beginArray("errorLabels");
    try b.putString("", "SystemOverloadedError");
    try b.putString("", "RetryableError");
    try b.putString("", "SomethingNewIn2030");
    try b.end();
    const reply = try b.finish();
    defer reply.deinit();

    const server = ServerError.fromReply(reply.raw());
    try testing.expectEqual(@as(i32, 462), server.code);
    try testing.expectEqualStrings("IngressRequestRateLimitExceeded", server.code_name.slice());
    try testing.expect(server.labels.contains(.system_overloaded_error));
    try testing.expect(server.labels.contains(.retryable_error));
    try testing.expectEqual(@as(usize, 2), server.labels.count());
    try testing.expectEqual(@as(u8, 1), server.unknown_labels);

    var d: Diagnostics = .{};
    d.setServer(.receive, reply.raw());
    try testing.expectEqual(@as(i32, 462), d.server.?.code);
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
    try testing.expectEqualStrings(long_errmsg[0..511], d.message());
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
}

test "a codeName longer than 64 bytes is cut by whole characters" {
    const name = @as([63]u8, @splat('N')) ++ "Ж".*;
    const reply = try bson.encode(testing.allocator, .{ .ok = 0, .code = 2, .codeName = @as([]const u8, &name) }, .{});
    defer reply.deinit();
    const server = ServerError.fromReply(reply.raw());
    try testing.expectEqualStrings(name[0..63], server.code_name.slice());
    // A name that fits stays whole.
    try testing.expectEqualStrings("BadValue", ServerError.Name.init("BadValue").slice());
}

test "a reply without the fields of an error gives code 0 and no name or labels" {
    const server = ServerError.fromReply(bson.literal(.{ .ok = 0, .code = "not a number", .errorLabels = 7 }));
    try testing.expectEqual(@as(i32, 0), server.code);
    try testing.expectEqualStrings("", server.code_name.slice());
    try testing.expectEqual(@as(usize, 0), server.labels.count());
    // A code beyond int32 is not a code of MongoDB.
    try testing.expectEqual(@as(i32, 0), ServerError.fromReply(bson.literal(.{ .ok = 0, .code = 3_000_000_000 })).code);
    // Labels that are not strings count as unknown ones, up to 255.
    try testing.expectEqual(@as(u8, 2), ServerError.fromReply(bson.literal(.{ .ok = 0, .errorLabels = .{ 1, true } })).unknown_labels);
}

test "a label is spelled as the server spells it" {
    const spelled = [_]struct { Label, []const u8 }{
        .{ .retryable_write_error, "RetryableWriteError" },
        .{ .transient_transaction_error, "TransientTransactionError" },
        .{ .unknown_transaction_commit_result, "UnknownTransactionCommitResult" },
        .{ .no_writes_performed, "NoWritesPerformed" },
        .{ .resumable_change_stream_error, "ResumableChangeStreamError" },
        .{ .system_overloaded_error, "SystemOverloadedError" },
        .{ .retryable_error, "RetryableError" },
    };
    try testing.expectEqual(spelled.len, @typeInfo(Label).@"enum".field_names.len);
    for (spelled) |row| {
        try testing.expectEqualStrings(row[1], row[0].name());
        try testing.expectEqual(row[0], Label.fromName(row[1]).?);
    }
    try testing.expectEqual(@as(?Label, null), Label.fromName("retryableError"));
}

test "the phase is open to new values" {
    try testing.expectEqual(std.lang.Type.Enum.Mode.nonexhaustive, @typeInfo(Diagnostics.Phase).@"enum".mode);
}
