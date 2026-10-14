//! The JSON codec of rpc: requests and responses as JSON, by their Zig
//! types. Internal to the module; `rpc.Server` and `rpc.Client` use it.
//!
//! - Integers up to 32 bits wide are JSON numbers. Integers of 33 to 64
//!   bits are strings of decimal digits ("9007199254740993"), so that
//!   clients in JavaScript, whose numbers are doubles, keep every digit.
//! - Floats are finite numbers, written so that they read back exactly.
//! - An enum is the name of its tag; an optional is `null` or the value;
//!   `[]const u8` is a string of UTF-8; other slices and arrays, `[N]u8`
//!   too, are JSON arrays.
//! - A struct is an object with its fields in the order of declaration; a
//!   `void` response is `{}`.
//!
//! `std.json` alone does not keep these rules: it writes big integers as
//! numbers and refuses unknown fields by default, for example.

const std = @import("std");
const dto = @import("dto.zig");

const Writer = std.Io.Writer;

pub const EncodeError = Writer.Error || error{
    /// A float is NaN or infinite: JSON has no such numbers.
    NonFinite,
    /// A string is not valid UTF-8.
    InvalidUtf8,
};

/// Writes `value` as JSON to `w`, without spaces. `T` is a DTO type or
/// `void` (see dto.zig); a NaN or an infinite float, or a string that is not
/// UTF-8, stops the encoding with an error, and `w` then holds a part of the
/// JSON.
pub fn encode(comptime T: type, value: *const T, w: *Writer) EncodeError!void {
    if (comptime dto.problem(T, .response)) |found| @compileError("rpc: json.encode: " ++ found);
    try write(T, value, w);
}

fn write(comptime T: type, value: *const T, w: *Writer) EncodeError!void {
    switch (@typeInfo(T)) {
        .void => try w.writeAll("{}"),
        .bool => try w.writeAll(if (value.*) "true" else "false"),
        .int => |info| if (info.bits <= 32) try w.print("{d}", .{value.*}) else try w.print("\"{d}\"", .{value.*}),
        .float => try writeFloat(T, value.*, w),
        .@"enum" => try writeString(@tagName(value.*), w),
        .optional => |info| if (value.*) |*inner| try write(info.child, inner, w) else try w.writeAll("null"),
        .pointer => |info| if (info.child == u8) try writeString(value.*, w) else try writeItems(info.child, value.*, w),
        .array => |info| try writeItems(info.child, value, w),
        .@"struct" => |info| {
            try w.writeByte('{');
            inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(name, w);
                try w.writeByte(':');
                try write(Field, &@field(value, name), w);
            }
            try w.writeByte('}');
        },
        else => @compileError("rpc: json.encode: unsupported type " ++ @typeName(T)),
    }
}

fn writeItems(comptime Item: type, items: []const Item, w: *Writer) EncodeError!void {
    try w.writeByte('[');
    for (items, 0..) |*item, i| {
        if (i > 0) try w.writeByte(',');
        try write(Item, item, w);
    }
    try w.writeByte(']');
}

fn writeString(text: []const u8, w: *Writer) EncodeError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

/// The shortest digits that read back as the same `T`: plain from 1e-6 up
/// to 1e21, with an exponent outside that range, as JavaScript writes
/// numbers.
fn writeFloat(comptime T: type, x: T, w: *Writer) EncodeError!void {
    if (!std.math.isFinite(x)) return error.NonFinite;
    const magnitude = @abs(x);
    const mode: std.fmt.float.Mode = if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) .decimal else .scientific;
    var buffer: [std.fmt.float.bufferSize(.decimal, T)]u8 = undefined;
    const text = std.fmt.float.render(&buffer, x, .{ .mode = mode }) catch unreachable;
    try w.writeAll(text);
}

const testing = std.testing;

/// `value` encoded, in a buffer that the test frees.
fn encoded(comptime T: type, value: T) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try encode(T, &value, &out.writer);
    return out.toOwnedSlice();
}

fn expectEncoded(comptime T: type, value: T, expected: []const u8) !void {
    const text = try encoded(T, value);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

const Color = enum { red, dark_green };
const Point = struct { x: i32, y: i32 };

test "integers up to 32 bits are numbers, wider ones are strings of digits" {
    try expectEncoded(u8, 255, "255");
    try expectEncoded(i32, std.math.minInt(i32), "-2147483648");
    try expectEncoded(u32, std.math.maxInt(u32), "4294967295");
    try expectEncoded(u1, 1, "1");
    try expectEncoded(u33, 0, "\"0\"");
    try expectEncoded(u64, std.math.maxInt(u64), "\"18446744073709551615\"");
    try expectEncoded(i64, std.math.minInt(i64), "\"-9223372036854775808\"");
    try expectEncoded(u64, 9007199254740993, "\"9007199254740993\"");
}

test "floats are finite and read back exactly" {
    try expectEncoded(f64, 1.5, "1.5");
    try expectEncoded(f64, 3, "3");
    try expectEncoded(f64, -0.0, "-0");
    try expectEncoded(f64, 0.1, "0.1");
    try expectEncoded(f32, 0.1, "0.1");
    try expectEncoded(f64, 1e20, "100000000000000000000");
    try expectEncoded(f64, 1e21, "1e21");
    try expectEncoded(f64, 1.5e-7, "1.5e-7");
    try expectEncoded(f64, 0.000001, "0.000001");
    try expectEncoded(f64, 5e-324, "5e-324");
    try expectEncoded(f64, std.math.floatMax(f64), "1.7976931348623157e308");
    try expectEncoded(f32, std.math.floatMax(f32), "3.4028235e38");
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| {
        var buffer: [64]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try testing.expectError(error.NonFinite, encode(f64, &bad, &w));
    }
    const nan32 = std.math.nan(f32);
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try testing.expectError(error.NonFinite, encode(f32, &nan32, &w));
}

test "strings are UTF-8 with JSON escapes" {
    try expectEncoded([]const u8, "", "\"\"");
    try expectEncoded([]const u8, "héllo, мир 😀", "\"héllo, мир 😀\"");
    try expectEncoded([]const u8, "a\"b\\c\nd\te\x00\x1f/", "\"a\\\"b\\\\c\\nd\\te\\u0000\\u001f/\"");
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const bad: []const u8 = "ab\xffcd";
    try testing.expectError(error.InvalidUtf8, encode([]const u8, &bad, &w));
    const surrogate: []const u8 = "\xed\xa0\x80";
    try testing.expectError(error.InvalidUtf8, encode([]const u8, &surrogate, &w));
}

test "enums are tag names, optionals null or the value, bools true and false" {
    try expectEncoded(Color, .dark_green, "\"dark_green\"");
    try expectEncoded(?u32, null, "null");
    try expectEncoded(?u32, 7, "7");
    try expectEncoded(?[]const u8, "x", "\"x\"");
    try expectEncoded(bool, true, "true");
    try expectEncoded(bool, false, "false");
}

test "slices and arrays are arrays, [N]u8 too; void is an empty object" {
    try expectEncoded([]const u32, &.{ 1, 2, 3 }, "[1,2,3]");
    try expectEncoded([]const u32, &.{}, "[]");
    try expectEncoded([3]u8, .{ 'a', 'b', 0 }, "[97,98,0]");
    try expectEncoded([0]u8, .{}, "[]");
    try expectEncoded([]const []const u8, &.{ "a", "b" }, "[\"a\",\"b\"]");
    try expectEncoded([2]Point, .{ .{ .x = 1, .y = 2 }, .{ .x = -3, .y = 4 } }, "[{\"x\":1,\"y\":2},{\"x\":-3,\"y\":4}]");
    try expectEncoded(void, {}, "{}");
}

const User = struct {
    id: u64,
    name: []const u8,
    email: ?[]const u8 = null,
    color: Color = .red,
    score: f32,
    tags: []const []const u8 = &.{},
    home: ?Point = null,
};

test "structs are objects with their fields in order, nulls written out" {
    try expectEncoded(User, .{ .id = 42, .name = "Ada", .score = 0.5 }, "{\"id\":\"42\",\"name\":\"Ada\",\"email\":null,\"color\":\"red\",\"score\":0.5,\"tags\":[],\"home\":null}");
    try expectEncoded(User, .{ .id = 1, .name = "B", .email = "b@x.io", .color = .dark_green, .score = -2, .tags = &.{"t"}, .home = .{ .x = 0, .y = -1 } }, "{\"id\":\"1\",\"name\":\"B\",\"email\":\"b@x.io\",\"color\":\"dark_green\",\"score\":-2,\"tags\":[\"t\"],\"home\":{\"x\":0,\"y\":-1}}");
    try expectEncoded(struct {}, .{}, "{}");
}

test "a writer that runs out of room stops the encoding" {
    var buffer: [8]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const value: User = .{ .id = 42, .name = "Ada", .score = 0.5 };
    try testing.expectError(error.WriteFailed, encode(User, &value, &w));
}
