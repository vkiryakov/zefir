//! Tests of odm.Error, odm.outcome and odm.Diagnostics.

const std = @import("std");
const testing = std.testing;
const odm = @import("../root.zig");
const Diagnostics = odm.Diagnostics;

test "outcome classes the 28 names of Error by table 5.11" {
    const not_sent = [_]odm.Error{
        error.InvalidArgument,      error.Unsupported,          error.Closed,
        error.Unavailable,          error.AuthenticationFailed, error.PoolExhausted,
        error.DeadlineExceeded,     error.Cancelled,            error.ValidationFailed,
        error.EncodeFailed,         error.TenantNotFound,       error.ConnectionNotFound,
        error.ConnectionExists,     error.ConnectionInUse,      error.StaleVersion,
        error.ProvisioningConflict, error.ShuttingDown,
    };
    const may_have_executed = [_]odm.Error{
        error.ConnectionLost,  error.Timeout,           error.Interrupted,
        error.IncompleteWrite, error.ProtocolViolation, error.CommandFailed,
        error.DuplicateKey,    error.WriteFailed,       error.InvalidBson,
        error.DecodeFailed,    error.OutOfMemory,
    };
    for (not_sent) |err| try testing.expectEqual(odm.Outcome.not_sent, odm.outcome(err));
    for (may_have_executed) |err| try testing.expectEqual(odm.Outcome.may_have_executed, odm.outcome(err));

    const driver_names = @typeInfo(odm.DriverError).error_set.error_names.?;
    const names = @typeInfo(odm.Error).error_set.error_names.?;
    try testing.expectEqual(@as(usize, 17), driver_names.len);
    try testing.expectEqual(@as(usize, 28), names.len);
    // Each name of Error is in exactly one of the two lists.
    inline for (names) |name| {
        var seen: usize = 0;
        for (not_sent ++ may_have_executed) |err| {
            if (std.mem.eql(u8, name, @errorName(err))) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    try testing.expectEqual(@as(usize, 1), @typeInfo(odm.ShutdownError).error_set.error_names.?.len);
}

test "set keeps a valid UTF-8 prefix of at most 512 bytes" {
    // "a" and 300 times "я", two bytes each: 601 bytes.
    var text: [1 + 300 * "я".len]u8 = undefined;
    text[0] = 'a';
    for (0..300) |i| @memcpy(text[1 + i * 2 ..][0..2], "я");

    var d: Diagnostics = .{};
    d.setPath("users.email");
    d.cause = error.WrongType;
    d.set(11000, 3, "{s}", .{text[1..]});
    try testing.expectEqual(@as(usize, 512), d.message().len);
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqualStrings(text[1..][0..512], d.message());
    try testing.expectEqual(@as(?i32, 11000), d.code);
    try testing.expectEqual(@as(?usize, 3), d.index);

    // The byte that "a" takes leaves room for half of the last "я": the
    // text stops before it.
    d.set(11000, 3, "{s}", .{&text});
    try testing.expectEqual(@as(usize, 511), d.message().len);
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqualStrings(text[0..511], d.message());
    try testing.expectEqual(@as(?i32, 11000), d.code);
    try testing.expectEqual(@as(?usize, 3), d.index);

    // The other fields stay as they were.
    try testing.expectEqualStrings("users.email", d.path());
    try testing.expectError(error.WrongType, @as(anyerror!void, d.cause.?));
    try testing.expect(d.violation == null);
}

test "set formats its arguments and writes bytes that are not UTF-8 as '?'" {
    var d: Diagnostics = .{};
    d.set(59, null, "no such command: '{s}' ({d})", .{ "fnd", 59 });
    try testing.expectEqualStrings("no such command: 'fnd' (59)", d.message());
    d.set(null, null, "{s}", .{"a\xffb\xc3"});
    try testing.expectEqualStrings("a?b", d.message());
    try testing.expectEqual(@as(?i32, null), d.code);
}

test "a copy keeps its own text and path" {
    var d: Diagnostics = .{};
    d.set(13, 1, "first", .{});
    d.setPath("address.city");
    const copy = d;
    d.set(11000, 2, "second", .{});
    d.setPath("email");
    try testing.expectEqualStrings("first", copy.message());
    try testing.expectEqualStrings("address.city", copy.path());
    try testing.expectEqual(@as(?i32, 13), copy.code);
    try testing.expectEqual(@as(?usize, 1), copy.index);
    try testing.expectEqualStrings("second", d.message());
    try testing.expectEqualStrings("email", d.path());
}

test "setPath keeps the end of a path over 256 bytes" {
    var d: Diagnostics = .{};
    d.setPath("");
    try testing.expectEqualStrings("", d.path());
    d.setPath("address.city");
    try testing.expectEqualStrings("address.city", d.path());

    // Exactly 256 bytes stay whole.
    const whole: [256]u8 = @splat('x');
    d.setPath(&whole);
    try testing.expectEqualStrings(&whole, d.path());

    // A path of fields: the end keeps whole fields behind "…".
    var fields: [1 + 60 * ".abcd".len]u8 = undefined;
    fields[0] = 'a';
    for (0..60) |i| @memcpy(fields[1 + i * 5 ..][0..5], ".abcd");
    d.setPath(&fields);
    try expectEnd(d.path(), &fields);
    try testing.expectStringStartsWith(d.path(), "….abcd");

    // One long name of two-byte characters: the cut falls between two of
    // them, never inside one.
    var name: [1 + 200 * "я".len]u8 = undefined;
    name[0] = 'a';
    for (0..200) |i| @memcpy(name[1 + i * 2 ..][0..2], "я");
    d.setPath(&name);
    try expectEnd(d.path(), &name);
}

/// A path cut from `full`: at most 256 bytes of UTF-8, "…" and then the
/// end of `full`.
fn expectEnd(path: []const u8, full: []const u8) !void {
    try testing.expect(path.len <= 256);
    try testing.expect(path.len > 200);
    try testing.expect(std.unicode.utf8ValidateSlice(path));
    try testing.expectStringStartsWith(path, "…");
    try testing.expectStringEndsWith(full, path["…".len..]);
}
