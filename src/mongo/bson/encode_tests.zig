//! Tests of the typed encoder: each row of the table of `bson.encode`,
//! through `encode` and through `Builder.put`, against the vectors.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const vectors = @import("vectors.zig");
const hex = vectors.hex;
const named = vectors.named;

/// A document of one field, "a", of type `T`.
fn One(comptime T: type) type {
    return struct { a: T };
}

/// {"a": value}, written by `bson.encode` and by `Builder.put`, is `expected`.
fn expectField(expected: []const u8, value: anytype) !void {
    const doc = try bson.encode(testing.allocator, One(@TypeOf(value)){ .a = value }, .{});
    defer doc.deinit();
    try testing.expectEqualSlices(u8, expected, doc.bytes);

    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.put("a", value);
    const built = try b.finish();
    defer built.deinit();
    try testing.expectEqualSlices(u8, expected, built.bytes);
}

/// {"a": value} is refused by `bson.encode` and by `Builder.put`.
fn expectRefused(value: anytype) !void {
    try testing.expectError(error.InvalidBson, bson.encode(testing.allocator, One(@TypeOf(value)){ .a = value }, .{}));
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try testing.expectError(error.InvalidBson, b.put("a", value));
}

fn expectEncoded(expected: []const u8, value: anytype, options: bson.EncodeOptions) !void {
    const doc = try bson.encode(testing.allocator, value, options);
    defer doc.deinit();
    try testing.expectEqualSlices(u8, expected, doc.bytes);
}

test "bool is a boolean" {
    try expectField(named("true"), true);
    try expectField(named("false"), false);
}

test "integers whose values all fit int32 are int32: i8 to i32, u8 to u16" {
    try expectField(hex("0c000000 10 6100 80ffffff 00"), @as(i8, -128));
    try expectField(hex("0c000000 10 6100 ff7f0000 00"), @as(i16, std.math.maxInt(i16)));
    try expectField(named("smallest int32"), @as(i32, std.math.minInt(i32)));
    try expectField(named("largest int32"), @as(i32, std.math.maxInt(i32)));
    try expectField(hex("0c000000 10 6100 ff000000 00"), @as(u8, 255));
    try expectField(hex("0c000000 10 6100 ffff0000 00"), @as(u16, std.math.maxInt(u16)));
    try expectField(named("int32"), @as(u1, 1));
    try expectField(named("largest int32"), @as(u31, std.math.maxInt(u31)));
}

test "wider integers are int64: i33 to i64, u32 to u63" {
    try expectField(named("int64"), @as(i33, 1));
    try expectField(named("int64 beyond int32"), @as(u32, 3_000_000_000));
    try expectField(hex("10000000 12 6100 ffffffff00000000 00"), @as(u32, std.math.maxInt(u32)));
    try expectField(named("largest int64"), @as(i64, std.math.maxInt(i64)));
    try expectField(named("smallest int64"), @as(i64, std.math.minInt(i64)));
    try expectField(named("largest int64"), @as(u63, std.math.maxInt(u63)));
}

test "f32 and f64 are doubles, NaN and the infinities included" {
    try expectField(named("double 2.5"), @as(f32, 2.5));
    try expectField(named("double 1.0"), @as(f64, 1.0));
    try expectField(named("double -0.0"), @as(f64, -0.0));
    try expectField(named("double 1e300"), @as(f64, 1e300));
    try expectField(named("double NaN"), std.math.nan(f64));
    try expectField(named("double +inf"), std.math.inf(f64));
    try expectField(named("double -inf"), -std.math.inf(f64));
    try expectField(named("double +inf"), std.math.inf(f32));
}

test "[]const u8 is a string, which must be UTF-8" {
    try expectField(named("string"), @as([]const u8, "Ann"));
    try expectField(named("empty string"), @as([]const u8, ""));
    try expectField(named("string in Cyrillic"), @as([]const u8, "Привет"));
    try expectField(named("string with a NUL"), @as([]const u8, "a\x00b"));
    // A stray byte, a cut sequence, a surrogate, an overlong form.
    for ([_][]const u8{ "\xff", "\xd0", "a\xed\xa0\x80", "\xc0\xaf" }) |text| {
        errdefer std.debug.print("text: {x}\n", .{text});
        try expectRefused(text);
    }
}

const Status = enum { active, blocked };

test "an exhaustive enum is the name of its tag" {
    try expectField(hex("13000000 02 6100 07000000 61637469766500 00"), Status.active);
    try expectField(hex("14000000 02 6100 08000000 626c6f636b656400 00"), Status.blocked);
}

test "an optional is null or its value; skip_nulls leaves the null fields out" {
    try expectField(named("null"), @as(?i32, null));
    try expectField(named("int32"), @as(?i32, 1));
    try expectEncoded(vectors.empty, One(?i32){ .a = null }, .{ .skip_nulls = true });
    try expectEncoded(named("int32"), One(?i32){ .a = 1 }, .{ .skip_nulls = true });
}

test "skip_nulls goes into documents, but an array keeps its null items" {
    const Inner = struct { b: ?i32, c: []const ?i32 };
    const value: One(Inner) = .{ .a = .{ .b = null, .c = &.{null} } };
    // {"a": {"b": null, "c": [null]}}
    try expectEncoded(hex("1b000000 03 6100 13000000 0a 6200 04 6300 08000000 0a 3000 00 00 00"), value, .{});
    // {"a": {"c": [null]}}
    try expectEncoded(hex("18000000 03 6100 10000000 04 6300 08000000 0a 3000 00 00 00"), value, .{ .skip_nulls = true });
}

test "a struct is a document, with its fields in their order" {
    const Pair = struct { b: i32, a: i32 };
    try expectEncoded(hex("13000000 10 6200 01000000 10 6100 02000000 00"), Pair{ .b = 1, .a = 2 }, .{});
    try expectField(named("document"), struct { b: i32 }{ .b = 1 });
    try expectField(named("empty document"), struct {}{});
    try expectEncoded(vectors.empty, struct {}{}, .{});
}

test "slices and arrays are arrays" {
    // {"a": [1, 2]}
    const numbers = hex("1b000000 04 6100 13000000 10 3000 01000000 10 3100 02000000 00 00");
    try expectField(numbers, @as([]const i32, &.{ 1, 2 }));
    try expectField(numbers, [2]i32{ 1, 2 });
    try expectField(named("empty array"), @as([]const i32, &.{}));
    try expectField(named("empty array"), [0]i32{});
    // {"a": ["x", "y"]}
    try expectField(hex("1f000000 04 6100 17000000 02 3000 02000000 7800 02 3100 02000000 7900 00 00"), @as([]const []const u8, &.{ "x", "y" }));
    // {"a": [{"b": 1}]}
    const Item = struct { b: i32 };
    try expectField(hex("1c000000 04 6100 14000000 03 3000 0c000000 10 6200 01000000 00 00 00"), @as([]const Item, &.{.{ .b = 1 }}));
    // [N]u8 is an array of numbers; a string is []const u8.
    try expectField(hex("14000000 04 6100 0c000000 10 3000 07000000 00 00"), [1]u8{7});
}

test "every value of every vector but the deprecated ones is written as it is" {
    for (vectors.valid) |vector| {
        if (deprecated(vector.value)) continue;
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        try expectField(vector.bson, vector.value);
    }
}

test "documents and the special types are written as they are" {
    const inner: bson.RawDocument = .{ .bytes = hex("0c000000 10 6200 01000000 00") };
    try expectField(named("document"), inner);
    const owned = try inner.dupe(testing.allocator);
    defer owned.deinit();
    try expectField(named("document"), owned);
    try expectField(named("ObjectId"), bson.ObjectId{ .bytes = vectors.object_id });
    try expectField(named("datetime with milliseconds"), bson.DateTime{ .milliseconds = 1356351330501 });
    try expectField(named("timestamp"), bson.Timestamp{ .seconds = 123456789, .increment = 42 });
    try expectField(named("binary"), bson.Binary{ .subtype = .generic, .bytes = &.{ 1, 2, 3 } });
    try expectField(named("Decimal128"), bson.Decimal128{ .bytes = hex("0f000000000000000000000000003e30").* });
    try expectField(named("regular expression"), bson.Regex{ .pattern = "^a.c", .options = "mi" });
    try expectField(named("null"), bson.Null{});
    try expectField(named("MinKey"), bson.MinKey{});
    try expectField(named("MaxKey"), bson.MaxKey{});
}

test "a broken document, a deprecated type or a string that is not UTF-8 in a Value is refused" {
    for (vectors.broken) |vector| {
        if (vector.caught_by == .init) continue;
        try expectRefused(bson.RawDocument{ .bytes = vector.bytes });
    }
    for (vectors.valid) |vector| {
        if (deprecated(vector.value)) try expectRefused(vector.value);
    }
    try expectRefused(bson.Value{ .string = "\xff" });
}

test "encode copies a RawDocument or an OwnedDocument after it checks it" {
    try expectEncoded(vectors.reply, bson.RawDocument{ .bytes = vectors.reply }, .{});
    const owned = try (bson.RawDocument{ .bytes = vectors.reply }).dupe(testing.allocator);
    defer owned.deinit();
    try expectEncoded(vectors.reply, owned, .{});
    for (vectors.broken) |vector| {
        if (vector.caught_by == .init) continue;
        try testing.expectError(error.InvalidBson, bson.encode(testing.allocator, bson.RawDocument{ .bytes = vector.bytes }, .{}));
    }
}

test "in an array, put lets the builder write the keys" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.beginArray("a");
    try b.put("", @as(i32, 1));
    try b.put("", @as([]const u8, "x"));
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, named("array"), doc.bytes);
}

test "a put that fails halfway leaves the document as it was" {
    const Deep = struct { x: i32, y: struct { z: []const u8 } };
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try testing.expectError(error.InvalidBson, b.put("a", Deep{ .x = 1, .y = .{ .z = "\xff" } }));
    try b.beginArray("a");
    try b.put("", @as(i32, 1));
    try testing.expectError(error.InvalidBson, b.put("", Deep{ .x = 1, .y = .{ .z = "\xff" } }));
    try testing.expectError(error.InvalidBson, b.put("", @as([]const []const u8, &.{ "ok", "\xff" })));
    try b.put("", @as([]const u8, "x"));
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, named("array"), doc.bytes);
}

test "a put counts its documents against the nesting limit" {
    const Two = struct { b: struct {} };
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    for (0..98) |_| try b.beginDocument("a");
    // The top level, 98 open and two more would make 101.
    try testing.expectError(error.InvalidBson, b.put("a", Two{ .b = .{} }));
    try b.put("a", struct {}{});
    for (0..98) |_| try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try (try bson.RawDocument.init(doc.bytes)).validate();
}

test "an anonymous literal writes integers by their value, strings and enum literals" {
    // {"age": 30, "name": "Ann", "status": "active"}
    try expectEncoded(hex("2f000000 10 61676500 1e000000 02 6e616d6500 04000000 416e6e00 02 73746174757300 07000000 61637469766500 00"), .{ .age = 30, .name = "Ann", .status = .active }, .{});
}

test "an integer literal is int32 when it fits, otherwise int64" {
    try expectEncoded(named("int32"), .{ .a = 1 }, .{});
    try expectEncoded(named("largest int32"), .{ .a = 2147483647 }, .{});
    try expectEncoded(named("smallest int32"), .{ .a = -2147483648 }, .{});
    try expectEncoded(hex("10000000 12 6100 0000008000000000 00"), .{ .a = 2147483648 }, .{});
    try expectEncoded(hex("10000000 12 6100 ffffff7fffffffff 00"), .{ .a = -2147483649 }, .{});
    try expectEncoded(named("int64 beyond int32"), .{ .a = 3_000_000_000 }, .{});
    try expectEncoded(named("largest int64"), .{ .a = 9223372036854775807 }, .{});
    try expectEncoded(named("smallest int64"), .{ .a = -9223372036854775808 }, .{});
}

test "a float literal is a double, null is null, an enum literal is the name of its tag" {
    try expectEncoded(named("double 2.5"), .{ .a = 2.5 }, .{});
    try expectEncoded(named("true"), .{ .a = true }, .{});
    try expectEncoded(named("null"), .{ .a = null }, .{});
    try expectEncoded(vectors.empty, .{ .a = null }, .{ .skip_nulls = true });
    try expectEncoded(hex("13000000 02 6100 07000000 61637469766500 00"), .{ .a = .active }, .{});
}

test "a tuple is an array" {
    // {"$in": [1, 2]}
    try expectEncoded(hex("1d000000 04 24696e00 13000000 10 3000 01000000 10 3100 02000000 00 00"), .{ .@"$in" = .{ 1, 2 } }, .{});
    try expectEncoded(named("array"), .{ .a = .{ 1, "x" } }, .{});
    // {"pipeline": [{"$match": {"a": 1}}, {"$limit": 5}]}
    try expectEncoded(
        hex("44000000 04 706970656c696e6500 35000000 03 3000 19000000 03 246d6174636800 0c000000 10 6100 01000000 00 00 03 3100 11000000 10 246c696d697400 05000000 00 00 00"),
        .{ .pipeline = .{ .{ .@"$match" = .{ .a = 1 } }, .{ .@"$limit" = 5 } } },
        .{},
    );
}

test ".{} is an empty document, at the top and in a field" {
    try expectEncoded(vectors.empty, .{}, .{});
    try expectEncoded(named("empty document"), .{ .a = .{} }, .{});
}

test "&.{ … } and &[_]T{ … } are arrays, &.{} an empty one, &[_]u8{ … } a string" {
    try expectEncoded(named("array"), .{ .a = &.{ 1, "x" } }, .{});
    // {"a": [1, 2]}
    try expectEncoded(hex("1b000000 04 6100 13000000 10 3000 01000000 10 3100 02000000 00 00"), .{ .a = &[_]i32{ 1, 2 } }, .{});
    try expectEncoded(named("empty array"), .{ .a = &.{} }, .{});
    try expectEncoded(named("string"), .{ .a = &[_]u8{ 'A', 'n', 'n' } }, .{});
}

test "the fields of a literal and the items of a tuple may be known only at run time" {
    var n: i32 = 1;
    var name: []const u8 = "x";
    _ = .{ &n, &name };
    try expectEncoded(named("int32"), .{ .a = n }, .{});
    try expectEncoded(named("array"), .{ .a = .{ n, name } }, .{});
    try expectEncoded(named("array"), .{ .a = &.{ n, name } }, .{});
}

test "the comptime fields of a declared struct are written like the others" {
    const Ping = struct { comptime ping: i32 = 1, comment: []const u8 };
    // {"ping": 1, "comment": "x"}
    try expectEncoded(hex("1e000000 10 70696e6700 01000000 02 636f6d6d656e7400 02000000 7800 00"), Ping{ .comment = "x" }, .{});
}

test "put writes literals too" {
    const cases = .{
        .{ named("document"), .{ .b = 1 } },
        .{ named("empty document"), .{} },
        .{ named("array"), .{ 1, "x" } },
        .{ named("empty array"), &.{} },
        .{ named("int32"), 1 },
        .{ named("int64 beyond int32"), 3_000_000_000 },
        .{ named("double 2.5"), 2.5 },
        .{ named("string"), "Ann" },
        .{ named("null"), null },
        .{ hex("13000000 02 6100 07000000 61637469766500 00"), .active },
    };
    inline for (cases) |case| {
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        try b.put("a", case[1]);
        const doc = try b.finish();
        defer doc.deinit();
        try testing.expectEqualSlices(u8, case[0], doc.bytes);
    }
}

test "a string literal that is not UTF-8 is refused" {
    try testing.expectError(error.InvalidBson, bson.encode(testing.allocator, .{ .a = "\xff" }, .{}));
    try testing.expectError(error.InvalidBson, bson.encode(testing.allocator, .{ .a = .{ "ok", "\xff" } }, .{}));
}

test "encode frees what it holds when it runs out of memory" {
    try testing.checkAllAllocationFailures(testing.allocator, encodeAndFree, .{});
}

fn encodeAndFree(allocator: std.mem.Allocator) !void {
    const Item = struct { name: []const u8, tags: []const []const u8 };
    const Doc = struct { items: []const Item, n: i64, note: ?[]const u8 };
    const value: Doc = .{ .items = &.{ .{ .name = "a", .tags = &.{ "x", "y" } }, .{ .name = "b", .tags = &.{} } }, .n = 5, .note = null };
    const doc = try bson.encode(allocator, value, .{});
    doc.deinit();
}

fn deprecated(value: bson.Value) bool {
    return switch (value) {
        .undefined, .db_pointer, .symbol, .javascript_with_scope => true,
        else => false,
    };
}
