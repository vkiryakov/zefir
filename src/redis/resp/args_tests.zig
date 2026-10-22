//! Tests of the arguments of commands: each row of the table of the
//! design's §3.2 as bytes, floats that read back bit for bit, and NaN,
//! which the check refuses before anything is written.

const std = @import("std");
const testing = std.testing;
const args = @import("args.zig");

/// The bytes that `args.write` gives for `value`. The caller frees them
/// with `testing.allocator`.
fn written(value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try args.write(.init(&out.writer), value);
    return out.toOwnedSlice();
}

fn expectWritten(expected: []const u8, value: anytype) !void {
    const bytes = try written(value);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
    try testing.expectEqual(@as(usize, 1), args.count(value));
}

/// The text of the one bulk string that `args.write` gives for `value`,
/// in `buffer`.
fn floatText(buffer: []u8, value: anytype) ![]const u8 {
    const bytes = try written(value);
    defer testing.allocator.free(bytes);
    const header_end = std.mem.find(u8, bytes, "\r\n") orelse return error.TestUnexpectedResult;
    const len = try std.fmt.parseInt(usize, bytes[1..header_end], 10);
    if (bytes.len < header_end + 2 + len) return error.TestUnexpectedResult;
    const text = bytes[header_end + 2 ..][0..len];
    try testing.expectEqualStrings("\r\n", bytes[header_end + 2 + len ..]);
    @memcpy(buffer[0..len], text);
    return buffer[0..len];
}

test "a string goes as it is, any byte included" {
    try expectWritten("$1\r\nk\r\n", "k");
    try expectWritten("$0\r\n\r\n", "");
    const key: []const u8 = "session:42";
    try expectWritten("$10\r\nsession:42\r\n", key);
    try expectWritten("$6\r\na\r\nb\x00c\r\n", "a\r\nb\x00c");
    var mutable = "abc".*;
    try expectWritten("$3\r\nabc\r\n", @as([]u8, &mutable));
    try expectWritten("$3\r\nabc\r\n", &mutable);
}

test "an integer of any width is its decimal text" {
    try expectWritten("$1\r\n0\r\n", @as(i64, 0));
    try expectWritten("$2\r\n-1\r\n", @as(i64, -1));
    try expectWritten("$20\r\n-9223372036854775808\r\n", std.math.minInt(i64));
    try expectWritten("$20\r\n-9223372036854775808\r\n", @as(i64, std.math.minInt(i64)));
    try expectWritten("$20\r\n18446744073709551615\r\n", @as(u64, std.math.maxInt(u64)));
    try expectWritten("$2\r\n42\r\n", 42);
    try expectWritten("$3\r\n255\r\n", @as(u8, 255));
    try expectWritten("$4\r\n-128\r\n", @as(i8, -128));
    try expectWritten("$39\r\n340282366920938463463374607431768211455\r\n", @as(u128, std.math.maxInt(u128)));
    try expectWritten("$1\r\n1\r\n", @as(u1, 1));
}

test "a float is its shortest text, inf and -inf included" {
    try expectWritten("$4\r\n12.5\r\n", 12.5);
    try expectWritten("$4\r\n12.5\r\n", @as(f64, 12.5));
    try expectWritten("$3\r\n0.1\r\n", @as(f64, 0.1));
    try expectWritten("$5\r\n1e300\r\n", @as(f64, 1e300));
    try expectWritten("$1\r\n3\r\n", @as(f64, 3));
    try expectWritten("$2\r\n-0\r\n", @as(f64, -0.0));
    try expectWritten("$3\r\ninf\r\n", std.math.inf(f64));
    try expectWritten("$4\r\n-inf\r\n", -std.math.inf(f64));
    try expectWritten("$3\r\ninf\r\n", std.math.inf(f32));
}

test "a float reads back bit for bit" {
    var buffer: [64]u8 = undefined;
    const values = [_]f64{ 0.1, 1e300, 5e-324, -0.0, std.math.floatMax(f64), -std.math.floatMin(f64), 12.5, 1.0 / 3.0, 123456789.125, 1e21, 1e-7 };
    for (values) |value| {
        const text = try floatText(&buffer, value);
        const back = try std.fmt.parseFloat(f64, text);
        testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(back))) catch |err| {
            std.debug.print("{e} went as {s}\n", .{ value, text });
            return err;
        };
    }
    try testing.expect(std.math.signbit(try std.fmt.parseFloat(f64, try floatText(&buffer, @as(f64, -0.0)))));

    // An f32 goes as the shortest text of the f32, which reads back as
    // the same f32.
    const tenth: f32 = 0.1;
    const text = try floatText(&buffer, tenth);
    try testing.expectEqualStrings("0.1", text);
    try testing.expectEqual(@as(u32, @bitCast(tenth)), @as(u32, @bitCast(try std.fmt.parseFloat(f32, text))));
}

test "NaN fails the check, and the check passes the rest" {
    try testing.expectError(error.InvalidArgument, args.check(std.math.nan(f64)));
    try testing.expectError(error.InvalidArgument, args.check(std.math.nan(f32)));
    try testing.expectError(error.InvalidArgument, args.check(-std.math.nan(f64)));
    try args.check(std.math.inf(f64));
    try args.check(@as(f64, 12.5));
    try args.check(12.5);
    try args.check("k");
    try args.check(@as(i64, 1));
    try args.check(true);
    try args.check(.pro);
}

test "a bool is 1 or 0" {
    try expectWritten("$1\r\n1\r\n", true);
    try expectWritten("$1\r\n0\r\n", false);
}

test "an enum is the name of its tag" {
    const Plan = enum { free, pro, @"pro-max" };
    try expectWritten("$3\r\npro\r\n", Plan.pro);
    const plan: Plan = .@"pro-max";
    try expectWritten("$7\r\npro-max\r\n", plan);
    try expectWritten("$3\r\npro\r\n", .pro);
}

test "a list of strings is as many arguments" {
    const keys: []const []const u8 = &.{ "a", "", "c\r\n" };
    const bytes = try written(keys);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("$1\r\na\r\n$0\r\n\r\n$3\r\nc\r\n\r\n", bytes);
    try testing.expectEqual(@as(usize, 3), args.count(keys));

    const array = [_][]const u8{ "x", "y" };
    const from_array = try written(&array);
    defer testing.allocator.free(from_array);
    try testing.expectEqualStrings("$1\r\nx\r\n$1\r\ny\r\n", from_array);
    try testing.expectEqual(@as(usize, 2), args.count(&array));

    const none: []const []const u8 = &.{};
    try testing.expectEqual(@as(usize, 0), args.count(none));
}

test "what can be an argument, as the comptime check sees it" {
    comptime {
        for ([_]type{ []const u8, []u8, *const [3:0]u8, *const [3]u8, *[3]u8 }) |T| {
            std.debug.assert(args.isString(T));
            std.debug.assert(!args.isStringList(T));
        }
        for ([_]type{ []const []const u8, [][]const u8, []const []u8, *const [2][]const u8 }) |T| {
            std.debug.assert(args.isStringList(T));
            std.debug.assert(!args.isString(T));
        }
        for ([_]type{ [*]const u8, []const i64, *const u8, [3]u8, ?[]const u8, struct { a: u8 } }) |T| {
            std.debug.assert(!args.isString(T));
            std.debug.assert(!args.isStringList(T));
        }
    }
}

test "a value written twice gives the same bytes" {
    const first = try written(@as(f64, 0.1));
    defer testing.allocator.free(first);
    const second = try written(@as(f64, 0.1));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}
