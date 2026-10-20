//! Tests of the comptime check of the typed codec: the message of each type
//! it refuses, with the path of the field, and the types it lets through.
//! `src/mongo/tests/compile_errors.zig` checks that the messages stop the
//! build.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const check = @import("check.zig");

fn expectProblem(comptime T: type, comptime direction: check.Direction, comptime expected: ?[]const u8) !void {
    const actual = comptime check.document(T, direction);
    if (expected) |text| {
        const found = actual orelse {
            std.debug.print("expected the problem: {s}\ngot none\n", .{text});
            return error.TestExpectedProblem;
        };
        try testing.expectEqualStrings(text, found);
    } else if (actual) |text| {
        std.debug.print("expected no problem, got: {s}\n", .{text});
        return error.TestUnexpectedProblem;
    }
}

fn expectBoth(comptime T: type, comptime expected: ?[]const u8) !void {
    try expectProblem(T, .encode, expected);
    try expectProblem(T, .decode, expected);
}

fn One(comptime T: type) type {
    return struct { a: T };
}

const Color = enum { red, green };
const Point = struct { x: f64, y: f64 };

const Every = struct {
    flag: bool,
    small: u1,
    count: u32,
    big: i64,
    narrow: i33,
    ratio: f32,
    color: Color,
    note: ?[]const u8 = null,
    name: []const u8,
    tags: []const []const u8,
    points: []const Point,
    pair: [2]u8,
    nested: ?struct { inner: [3]Color } = null,
    empty: struct {} = .{},
    raw: bson.RawDocument,
    value: bson.Value,
    id: bson.ObjectId,
    at: bson.DateTime,
    stamp: bson.Timestamp,
    data: bson.Binary,
    number: bson.Decimal128,
    pattern: bson.Regex,
    nothing: bson.Null,
    min: bson.MinKey,
    max: bson.MaxKey,

    pub fn helper() void {}
};

test "every type of the table passes both ways, and declarations do not count" {
    try expectBoth(Every, null);
    try expectBoth(struct {}, null);
}

test "literals, tuples, pointers to lists and OwnedDocument only encode" {
    const Literal = @TypeOf(.{ .age = 30, .ratio = 0.5, .name = "Ann", .status = .active, .none = null, .in = .{ 1, "x" }, .list = &.{ 1, 2 }, .empty = &.{}, .array = &[_]i32{1} });
    try expectProblem(Literal, .encode, null);
    try expectProblem(@TypeOf(.{}), .encode, null);
    try expectProblem(bson.RawDocument, .encode, null);
    try expectProblem(bson.OwnedDocument, .encode, null);
    try expectProblem(One(bson.OwnedDocument), .encode, null);
    try expectProblem(One(comptime_int), .decode, "field 'a' is comptime_int, the type of a literal: decode needs a type such as i64, f64, []const u8 or an enum");
    try expectProblem(One(@TypeOf(null)), .decode, "field 'a' is @TypeOf(null), the type of a literal: decode needs a type such as i64, f64, []const u8 or an enum");
    try expectProblem(One(struct { i32, i32 }), .decode, "field 'a' is struct { i32, i32 }, a tuple: decode needs the names of fields; use a struct, or a slice for an array");
    try expectProblem(One(*const [2]i32), .decode, "field 'a' is *const [2]i32: decode fills values, not pointers; use [2]i32");
    try expectProblem(One(bson.OwnedDocument), .decode, "field 'a' is " ++ @typeName(bson.OwnedDocument) ++ ": decode into a bson.RawDocument, whose bytes live in the arena");
    try expectProblem(struct { comptime version: u32 = 1 }, .decode, "field 'version' is a comptime field: decode fills only fields known at run time");
}

test "the deprecated types only decode" {
    try expectProblem(One(bson.DbPointer), .decode, null);
    try expectProblem(One(bson.JavaScriptWithScope), .decode, null);
    try expectProblem(One(bson.DbPointer), .encode, "field 'a' is " ++ @typeName(bson.DbPointer) ++ ", a deprecated type: it is read, never written");
}

test "the document is a struct with named fields, or a document as it is to encode" {
    try expectProblem(u32, .encode, "a document is a struct with named fields, such as .{ .name = name }, or a bson.RawDocument; got u32");
    try expectProblem(?Point, .encode, "a document is a struct with named fields, such as .{ .name = name }, or a bson.RawDocument; got ?" ++ @typeName(Point));
    try expectProblem(bson.ObjectId, .encode, "a document is a struct with named fields, such as .{ .name = name }, or a bson.RawDocument; got " ++ @typeName(bson.ObjectId));
    try expectProblem(@TypeOf(.{ 1, 2 }), .encode, "a tuple is an array, not a document: give its values names, such as .{ .a = x }");
    try expectProblem([]const Point, .decode, "decode fills a struct with named fields; got []const " ++ @typeName(Point));
    try expectProblem(bson.RawDocument, .decode, "decode fills a struct with named fields; got " ++ @typeName(bson.RawDocument));
}

test "integers have a fixed width of at most 64 bits, and u64 has no BSON type" {
    try expectBoth(One(u64), "field 'a' is u64, which BSON has no type for: its integers are signed; use i64");
    try expectBoth(One(usize), "field 'a' is usize, whose size depends on the target: use i64 or i32");
    try expectBoth(One(isize), "field 'a' is isize, whose size depends on the target: use i64 or i32");
    try expectBoth(One(c_int), "field 'a' is c_int, whose size depends on the target: use an integer of a fixed width, such as i32");
    try expectBoth(One(c_ulong), "field 'a' is c_ulong, whose size depends on the target: use an integer of a fixed width, such as i32");
    try expectBoth(One(i65), "field 'a' is i65: BSON integers have at most 64 bits; use i64");
    try expectBoth(One(u128), "field 'a' is u128: BSON integers have at most 64 bits; use i64");
    try expectBoth(One(u63), null);
    try expectBoth(One(u0), null);
}

test "floats are f32 or f64" {
    try expectBoth(One(f16), "field 'a' is f16: a BSON double is an f64; use f64 or f32");
    try expectBoth(One(f128), "field 'a' is f128: a BSON double is an f64; use f64 or f32");
}

const Open = enum(u8) { a, _ };
const Odd = enum { @"\xff", ok };

test "an enum is exhaustive, with tags that are UTF-8" {
    try expectBoth(One(Open), "field 'a' is " ++ @typeName(Open) ++ ", a non-exhaustive enum: a value without a tag has no name to write; make the enum exhaustive");
    try expectBoth(One(Odd), "field 'a' is " ++ @typeName(Odd) ++ ": the name of one of its tags is not UTF-8");
    try expectProblem(@TypeOf(.{ .a = .@"\xfe" }), .encode, "field 'a' is an enum literal whose name is not UTF-8");
}

test "an optional of an optional cannot be told apart from it" {
    try expectBoth(One(??u32), "field 'a' is ??u32: BSON null cannot tell the two nulls apart");
    try expectBoth(One([]const ??u32), "field 'a[]' is ??u32: BSON null cannot tell the two nulls apart");
}

test "pointers other than slices and lists stop the build; decode takes const slices without a sentinel" {
    try expectProblem(One(*const Point), .encode, "field 'a' is *const " ++ @typeName(Point) ++ ": pass the value itself, not a pointer to it");
    try expectProblem(One(*const Point), .decode, "field 'a' is *const " ++ @typeName(Point) ++ ": decode fills values, not pointers; use " ++ @typeName(Point));
    try expectBoth(One([*]const u8), "field 'a' is [*]const u8, which has no length: pass a slice");
    try expectBoth(One([*c]const u8), "field 'a' is [*c]const u8, which has no length: pass a slice");
    try expectProblem(One([]u8), .encode, null);
    try expectProblem(One([:0]const u8), .encode, null);
    try expectProblem(One([]u8), .decode, "field 'a' is []u8: decode gives const slices; use []const u8");
    try expectProblem(One([:0]const u8), .decode, "field 'a' is [:0]const u8: decode gives slices without a sentinel; use []const u8");
    try expectProblem(One([4:0]u8), .encode, null);
    try expectProblem(One([4:0]u8), .decode, "field 'a' is [4:0]u8: decode fills arrays without a sentinel");
}

const Shape = union(enum) { circle: f64, square: f64 };

test "a union stops the build, but bson.Value passes" {
    try expectBoth(One(Shape), "field 'a' is " ++ @typeName(Shape) ++ ": unions are not supported; a field of any BSON type is a bson.Value");
    try expectBoth(One(bson.Value), null);
}

const Node = struct { name: []const u8, children: []const Node };
const Parent = struct { child: ?Child };
const Child = struct { parents: []const Parent };
const Shared = struct { a: Point, b: Point, c: []const Point };

test "a type that holds itself stops the build; a type used twice does not" {
    try expectBoth(Shared, null);
    try expectBoth(Node, "field 'children[]' is " ++ @typeName(Node) ++ " inside itself: a type that holds itself is not supported");
    try expectBoth(Parent, "field 'child.parents[]' is " ++ @typeName(Parent) ++ " inside itself: a type that holds itself is not supported");
}

const Owner = struct { id: u64 };
const Item = struct { owner: Owner };
const Order = struct { items: []const Item, pairs: [2]?struct { n: usize } };

test "the path names each field, and the items of slices, arrays and tuples" {
    try expectBoth(Order, "field 'items[].owner.id' is u64, which BSON has no type for: its integers are signed; use i64");
    try expectBoth(struct { pairs: [2]?struct { n: usize } }, "field 'pairs[].n' is usize, whose size depends on the target: use i64 or i32");
    try expectProblem(@TypeOf(.{ .in = .{ 1, @as(u64, 2) } }), .encode, "field 'in[1]' is u64, which BSON has no type for: its integers are signed; use i64");
    try expectProblem(@TypeOf(.{ .in = &.{ 1, @as(u64, 2) } }), .encode, "field 'in[1]' is u64, which BSON has no type for: its integers are signed; use i64");
    try testing.expectEqualStrings("the value is u64, which BSON has no type for: its integers are signed; use i64", comptime check.value(u64, .encode).?);
    try testing.expectEqualStrings("field '[]' is u64, which BSON has no type for: its integers are signed; use i64", comptime check.value([]const u64, .encode).?);
}

test "an integer literal beyond int64 stops the build" {
    try expectProblem(@TypeOf(.{ .a = 9223372036854775807, .b = -9223372036854775808 }), .encode, null);
    try expectProblem(@TypeOf(.{ .a = 9223372036854775808 }), .encode, "field 'a' is 9223372036854775808, which does not fit int64");
    try expectProblem(@TypeOf(.{ .a = .{ 1, -9223372036854775809 } }), .encode, "field 'a[1]' is -9223372036854775809, which does not fit int64");
}

const BadName = struct { @"\xff": i32 };

test "the name of a field is UTF-8" {
    try expectBoth(BadName, "the value is " ++ @typeName(BadName) ++ ": the name of one of its fields is not UTF-8");
}

test "functions, void, error unions and types have no BSON type" {
    try expectBoth(One(void), "field 'a' is void, which has no BSON type");
    try expectBoth(One(anyerror!u32), "field 'a' is anyerror!u32, which has no BSON type");
    try expectBoth(One(fn () void), "field 'a' is fn () void, which has no BSON type");
    try expectBoth(One(type), "field 'a' is type, which has no BSON type");
}
