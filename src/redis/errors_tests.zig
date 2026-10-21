//! Tests of the errors of the client: the class of every name, and what
//! `Diagnostics` keeps of the texts of the server and of the client.

const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;

test "every name of redis.Error has the class of the design's table" {
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
        .{ "ProtocolViolation", .may_have_executed },
        .{ "ReplyTooLarge", .may_have_executed },
        .{ "ServerError", .may_have_executed },
        .{ "UnexpectedReply", .may_have_executed },
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

/// A command of a pipeline gives its error as a value; the caller's
/// function returns `redis.Error`.
fn first(result: errors.CommandError!i64) errors.Error!i64 {
    return try result;
}

test "a CommandError is a redis.Error: try lifts it" {
    try testing.expectEqual(@as(i64, 7), try first(7));
    try testing.expectError(error.ServerError, first(error.ServerError));
    try testing.expectError(error.UnexpectedReply, first(error.UnexpectedReply));
}

test "a server text longer than the buffer is cut before a character that does not fit whole" {
    var d: Diagnostics = .{};
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqualStrings("", d.code());
    // 600 bytes: "ERR " and 'a' up to byte 511, then "ж" (2 bytes) across
    // the end of the 512-byte buffer.
    var text: [600]u8 = undefined;
    @memcpy(text[0..4], "ERR ");
    @memset(text[4..511], 'a');
    @memcpy(text[511..513], "ж");
    @memset(text[513..], 'b');
    d.setServer(.receive, &text);
    try testing.expectEqual(@as(usize, 511), d.message().len);
    try testing.expectEqualStrings(text[0..511], d.message());
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqualStrings("ERR", d.code());
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
    try testing.expectEqual(@as(?anyerror, null), d.cause);

    // A character that ends right at the end of the buffer stays.
    const exact = "ERR ".* ++ @as([506]u8, @splat('c')) ++ "ж".*;
    const longer = exact ++ "and more".*;
    d.setServer(.receive, &longer);
    try testing.expectEqualStrings(&exact, d.message());
}

test "a byte that is not UTF-8 becomes '?', in the message and in the code" {
    var d: Diagnostics = .{};
    d.setServer(.receive, "WRONG\xffTYPE Operation \xc3(x");
    try testing.expectEqualStrings("WRONG?TYPE Operation ?(x", d.message());
    try testing.expectEqualStrings("WRONG?TYPE", d.code());
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
}

test "code() is the first word of the server's text, at most 32 bytes" {
    var d: Diagnostics = .{};
    d.setServer(.receive, "WRONGTYPE Operation against a key holding the wrong kind of value");
    try testing.expectEqualStrings("WRONGTYPE", d.code());
    try testing.expectEqualStrings("WRONGTYPE Operation against a key holding the wrong kind of value", d.message());
    try testing.expect(d.isCode("WRONGTYPE"));
    try testing.expect(!d.isCode("WRONG"));
    try testing.expect(!d.isCode("WRONGTYPES"));
    try testing.expect(!d.isCode(""));

    const long = @as([40]u8, @splat('X')) ++ " the rest".*;
    d.setServer(.receive, &long);
    try testing.expectEqualStrings(long[0..32], d.code());
    try testing.expectEqualStrings(&long, d.message());

    // A text of one word is all code.
    d.setServer(.receive, "NOAUTH");
    try testing.expectEqualStrings("NOAUTH", d.code());
    try testing.expectEqualStrings("NOAUTH", d.message());
}

test "a client's text has no code, and replaces a server's" {
    var d: Diagnostics = .{};
    d.setServer(.receive, "ERR boom");
    d.set(.send, error.BrokenPipe, "wrote {d} of {d} bytes", .{ 12, 40 });
    try testing.expectEqualStrings("wrote 12 of 40 bytes", d.message());
    try testing.expectEqualStrings("", d.code());
    try testing.expect(!d.isCode("ERR"));
    try testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
    try testing.expectEqual(error.BrokenPipe, d.cause.?);

    // A long client text is cut the same way as a server's.
    const cut = @as([511]u8, @splat('a')) ++ "ж".*;
    d.set(null, null, "{s}", .{&cut});
    try testing.expectEqual(@as(usize, 511), d.message().len);
    try testing.expectEqual(@as(?Diagnostics.Phase, null), d.phase);
    try testing.expectEqual(@as(?anyerror, null), d.cause);
}

test "refused() is null until its setter, then the refused command's code and text" {
    var d: Diagnostics = .{};
    try testing.expect(d.refused() == null);
    d.setServer(.receive, "EXECABORT Transaction discarded because of previous errors.");
    d.setRefused("NOPERM User u has no permissions to run the 'set' command");
    d.command = 1;
    const refused = d.refused().?;
    try testing.expectEqualStrings("NOPERM", refused.code);
    try testing.expectEqualStrings("NOPERM User u has no permissions to run the 'set' command", refused.message);
    // The refusal leaves the error of EXEC as it was.
    try testing.expectEqualStrings("EXECABORT", d.code());
    try testing.expectEqualStrings("EXECABORT Transaction discarded because of previous errors.", d.message());
    try testing.expectEqual(@as(?usize, 1), d.command);

    // A long refusal is cut like any text of the server.
    var long: [600]u8 = undefined;
    @memcpy(long[0..4], "ERR ");
    @memset(long[4..511], 'a');
    @memcpy(long[511..513], "ж");
    @memset(long[513..], 'b');
    d.setRefused(&long);
    try testing.expectEqualStrings(long[0..511], d.refused().?.message);
    try testing.expectEqualStrings("ERR", d.refused().?.code);
}

test "a new Diagnostics holds nothing" {
    const d: Diagnostics = .{};
    try testing.expectEqual(@as(?Diagnostics.Phase, null), d.phase);
    try testing.expectEqual(@as(?anyerror, null), d.cause);
    try testing.expectEqual(@as(?usize, null), d.command);
    try testing.expectEqual(@as(?usize, null), d.answered);
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqualStrings("", d.code());
    try testing.expect(d.refused() == null);
}

test "Phase is non-exhaustive and has tls" {
    try testing.expectEqual(std.lang.Type.Enum.Mode.nonexhaustive, @typeInfo(Diagnostics.Phase).@"enum".mode);
    try testing.expect(@hasField(Diagnostics.Phase, "tls"));
    const later: Diagnostics.Phase = @fromBackingInt(200);
    const known = switch (later) {
        .checkout, .connect, .tls, .handshake, .send, .wait, .receive => true,
        _ => false,
    };
    try testing.expect(!known);
}
