//! Tests of scheduler.Diagnostics.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const Diagnostics = scheduler.Diagnostics;

/// `n` times the two bytes of "я", after `head`.
fn repeated(buffer: []u8, head: []const u8, n: usize) []const u8 {
    @memcpy(buffer[0..head.len], head);
    var end = head.len;
    for (0..n) |_| {
        @memcpy(buffer[end..][0..2], "я");
        end += 2;
    }
    return buffer[0..end];
}

test "set keeps a valid UTF-8 prefix of at most 256 bytes" {
    var buffer: [512]u8 = undefined;
    var d: Diagnostics = .{};

    // 400 bytes: the cut falls between two characters.
    d.set(null, "{s}", .{repeated(&buffer, "", 200)});
    try testing.expectEqual(256, d.message().len);
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqualStrings(repeated(&buffer, "", 128), d.message());

    // 401 bytes: the 256th byte starts a character, which is dropped whole.
    d.set(null, "{s}", .{repeated(&buffer, "a", 200)});
    try testing.expectEqual(255, d.message().len);
    try testing.expect(std.unicode.utf8ValidateSlice(d.message()));
    try testing.expectEqualStrings(repeated(&buffer, "a", 127), d.message());

    // A byte that is not UTF-8 becomes '?', and the rest of the text stays.
    d.set(null, "cron \"{s}\": not a field", .{"0 \xff"});
    try testing.expectEqualStrings("cron \"0 ?\": not a field", d.message());
}

test "set replaces the text and the code" {
    var d: Diagnostics = .{};
    d.set(11600, "first: {d}", .{1});
    try testing.expectEqual(@as(?i32, 11600), d.code);
    try testing.expectEqualStrings("first: 1", d.message());

    d.set(null, "second", .{});
    try testing.expectEqual(@as(?i32, null), d.code);
    try testing.expectEqualStrings("second", d.message());

    // A text may quote the one it replaces.
    d.set(7, "again: {s}", .{d.message()});
    try testing.expectEqual(@as(?i32, 7), d.code);
    try testing.expectEqualStrings("again: second", d.message());
}

test "a copy keeps its own text" {
    var d: Diagnostics = .{};
    d.set(1, "original", .{});
    const copy = d;
    d.set(2, "changed", .{});
    try testing.expectEqualStrings("original", copy.message());
    try testing.expectEqual(@as(?i32, 1), copy.code);
    try testing.expectEqualStrings("changed", d.message());
}

test "message is empty before set" {
    const d: Diagnostics = .{};
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqual(@as(?i32, null), d.code);
}
