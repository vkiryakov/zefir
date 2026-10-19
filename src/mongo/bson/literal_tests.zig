//! Tests of `bson.literal`: the bytes it writes at compile time are those
//! of the vectors and those that `bson.encode` writes at run time.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const vectors = @import("vectors.zig");
const hex = vectors.hex;

/// `bson.literal(value)` holds the bytes of `bson.encode(value)`.
fn expectSame(comptime value: anytype) !void {
    const doc = try bson.encode(testing.allocator, value, .{});
    defer doc.deinit();
    const literal = bson.literal(value);
    try testing.expectEqualSlices(u8, doc.bytes, literal.bytes);
    try literal.validate();
}

test "bson.literal(.{ .email = 1 }) and bson.literal(.{}) are the bytes of encode" {
    try testing.expectEqualSlices(u8, hex("10000000 10 656d61696c00 01000000 00"), bson.literal(.{ .email = 1 }).bytes);
    try testing.expectEqualSlices(u8, vectors.empty, bson.literal(.{}).bytes);
    try expectSame(.{ .email = 1 });
    try expectSame(.{});
}

test "literal writes every vector that is not deprecated byte for byte" {
    inline for (vectors.valid) |vector| {
        if (comptime deprecated(vector.value)) continue;
        try testing.expectEqualSlices(u8, vector.bson, bson.literal(.{ .a = vector.value }).bytes);
    }
}

const Status = enum { active, blocked };

const Every = struct {
    flag: bool,
    small: i8,
    word: u16,
    int: i32,
    unsigned: u32,
    long: i64,
    single: f32,
    double: f64,
    text: []const u8,
    status: Status,
    missing: ?i32,
    present: ?[]const u8,
    inner: struct { b: i32, c: struct {} },
    list: []const i32,
    pair: [2]bool,
    names: []const []const u8,
    raw: bson.RawDocument,
    value: bson.Value,
    id: bson.ObjectId,
    at: bson.DateTime,
    stamp: bson.Timestamp,
    data: bson.Binary,
    old: bson.Binary,
    number: bson.Decimal128,
    pattern: bson.Regex,
    nothing: bson.Null,
    min: bson.MinKey,
    max: bson.MaxKey,
};

const every: Every = .{
    .flag = true,
    .small = -5,
    .word = 65535,
    .int = std.math.minInt(i32),
    .unsigned = std.math.maxInt(u32),
    .long = std.math.minInt(i64),
    .single = 1.5,
    .double = -1e300,
    .text = "Привет",
    .status = .blocked,
    .missing = null,
    .present = "x",
    .inner = .{ .b = 7, .c = .{} },
    .list = &.{ 1, 2, 3 },
    .pair = .{ true, false },
    .names = &.{ "a", "" },
    .raw = .{ .bytes = vectors.reply },
    .value = .{ .javascript = "x=1" },
    .id = .{ .bytes = vectors.object_id },
    .at = .{ .milliseconds = -1 },
    .stamp = .{ .seconds = 2355942023, .increment = 105 },
    .data = .{ .subtype = .uuid, .bytes = &.{ 0xea, 0x88 } },
    .old = .{ .subtype = .binary_old, .bytes = &.{ 0x1c, 0x49, 0xf5 } },
    .number = .{ .bytes = hex("0f000000000000000000000000003e30").* },
    .pattern = .{ .pattern = "^a.c", .options = "xmi" },
    .nothing = .{},
    .min = .{},
    .max = .{},
};

test "literal and encode agree on every row of the table" {
    try expectSame(every);
    try expectSame(.{ .doc = every, .docs = &.{ every, every } });
}

test "literal and encode agree on the fields of anonymous literals" {
    try expectSame(.{ .age = 30, .name = "Ann", .status = .active });
    try expectSame(.{ .@"$in" = .{ 1, 2 } });
    try expectSame(.{ .pipeline = .{ .{ .@"$match" = .{ .a = 1 } }, .{ .@"$limit" = 5 } } });
    try expectSame(.{ .a = 2147483647, .b = 2147483648, .c = -2147483649, .d = -9223372036854775808 });
    try expectSame(.{ .a = 2.5, .b = null, .c = .{}, .d = &.{}, .e = &[_]i32{ 1, 2 }, .f = &.{ 1, "x" } });
    try expectSame(.{ .a = &[_]u8{ 'A', 'n', 'n' }, .b = [_]u8{ 1, 2 }, .c = @as(?i32, 4) });
}

test "a literal nests other literals" {
    const keys = comptime bson.literal(.{ .email = 1, .age = -1 });
    try expectSame(.{ .key = keys, .name = "email_1_age_-1", .unique = true });
    try expectSame(.{ .key = bson.literal(.{ .email = 1 }) });
}

test "a literal is static: two calls give the same bytes" {
    const a = byAge();
    const b = byAge();
    try testing.expectEqual(a.bytes.ptr, b.bytes.ptr);
    try testing.expectEqualSlices(u8, hex("0e000000 10 61676500 ffffffff 00"), a.bytes);
}

fn byAge() bson.RawDocument {
    return bson.literal(.{ .age = -1 });
}

test "literal takes a RawDocument known at compile time as it is" {
    const reply = comptime bson.RawDocument{ .bytes = vectors.reply };
    try testing.expectEqualSlices(u8, vectors.reply, bson.literal(reply).bytes);
}

fn deprecated(value: bson.Value) bool {
    return switch (value) {
        .undefined, .db_pointer, .symbol, .javascript_with_scope => true,
        else => false,
    };
}
