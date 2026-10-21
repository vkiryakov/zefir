//! Calls of the BSON codec that must not compile, one test each.
//! `zig build test-mongo-bson` compiles every test on its own and checks
//! its error message; the list of messages is in build.zig.

const std = @import("std");
const bson = @import("mongo-bson");

/// Never called at run time: these tests only have to fail to compile.
fn arena() std.mem.Allocator {
    return undefined;
}

fn doc() bson.RawDocument {
    return undefined;
}

const Counter = struct { n: u64 };
const Sized = struct { n: usize };
const Signed = struct { n: isize };
const CInt = struct { n: c_int };
const Open = enum(u8) { a, _ };
const WithOpen = struct { kind: Open };
const Shape = union(enum) { circle: f64, square: f64 };
const Drawing = struct { shape: Shape };
const User = struct { name: []const u8 };
const Post = struct { owner: *const User };
const Name = struct { name: [*]const u8 };
const Node = struct { name: []const u8, children: []const Node };
const Twice = struct { n: ??u32 };
const Owner = struct { id: u64 };
const Item = struct { owner: Owner };
const Order = struct { items: []const Item };
const Pointer = struct { p: bson.DbPointer };
const Pair = struct { pair: struct { i32, i32 } };
const Versioned = struct { comptime version: u32 = 1 };
const Mutable = struct { name: []u8 };

test "u64" {
    _ = try bson.encode(arena(), Counter{ .n = 1 }, .{});
}

test "usize" {
    _ = try bson.encode(arena(), Sized{ .n = 1 }, .{});
}

test "isize" {
    _ = try bson.decode(Signed, arena(), doc(), .{});
}

test "c_int" {
    _ = try bson.encode(arena(), CInt{ .n = 1 }, .{});
}

test "non-exhaustive enum" {
    _ = try bson.encode(arena(), WithOpen{ .kind = .a }, .{});
}

test "union" {
    _ = try bson.decode(Drawing, arena(), doc(), .{});
}

test "pointer" {
    const ann: User = .{ .name = "Ann" };
    _ = try bson.encode(arena(), Post{ .owner = &ann }, .{});
}

test "many-item pointer" {
    _ = try bson.encode(arena(), Name{ .name = "Ann" }, .{});
}

test "type that holds itself" {
    _ = try bson.encode(arena(), Node{ .name = "root", .children = &.{} }, .{});
}

test "optional of an optional" {
    _ = try bson.encode(arena(), Twice{ .n = null }, .{});
}

test "path of a nested field" {
    _ = try bson.decode(Order, arena(), doc(), .{});
}

test "put of a u64" {
    var b: bson.Builder = .init(arena());
    try b.put("n", @as(u64, 1));
}

test "literal of a string that is not UTF-8" {
    _ = bson.literal(.{ .a = "\xff" });
}

test "literal of a regular expression that is not UTF-8" {
    _ = bson.literal(.{ .a = bson.Regex{ .pattern = "^\xff", .options = "" } });
}

test "integer literal beyond int64" {
    _ = try bson.encode(arena(), .{ .n = 9223372036854775808 }, .{});
}

test "tuple as a document" {
    _ = try bson.encode(arena(), .{ 1, 2 }, .{});
}

test "number as a document" {
    _ = try bson.encode(arena(), @as(u32, 1), .{});
}

test "deprecated type to encode" {
    _ = try bson.encode(arena(), Pointer{ .p = undefined }, .{});
}

test "tuple to decode" {
    _ = try bson.decode(Pair, arena(), doc(), .{});
}

test "comptime field to decode" {
    _ = try bson.decode(Versioned, arena(), doc(), .{});
}

test "mutable slice to decode" {
    _ = try bson.decode(Mutable, arena(), doc(), .{});
}
