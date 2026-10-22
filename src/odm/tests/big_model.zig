//! The 50-field model of the compile-time measurements (design §10, Р50):
//! 20 top-level fields of every kind, and three structs of 10 fields, one
//! of which holds a struct of 10, 63 paths in all. Its tests are named
//! "big model: …", so that a build can take them alone.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const filter = @import("../query/filter.zig");
const options = @import("../query/options.zig");

pub const Kind = enum { one, two, three };

pub const D = struct {
    d0: bool,
    d1: i32,
    d2: i64,
    d3: u16,
    d4: u32,
    d5: f64,
    d6: []const u8,
    d7: Kind,
    d8: bson.DateTime,
    d9: bson.ObjectId,
};

pub const A = struct {
    a0: bool,
    a1: i32,
    a2: i64,
    a3: u16,
    a4: u32,
    a5: f64,
    a6: []const u8,
    a7: Kind,
    a8: bson.DateTime,
    deep: D,
};

pub const B = struct {
    b0: bool,
    b1: i32,
    b2: i64,
    b3: u16,
    b4: u32,
    b5: f64,
    b6: []const u8,
    b7: Kind,
    b8: bson.DateTime,
    b9: bson.ObjectId,
};

pub const C = struct {
    c0: bool,
    c1: i32,
    c2: i64,
    c3: u16,
    c4: u32,
    c5: f64,
    c6: []const u8,
    c7: Kind,
    c8: bson.DateTime,
    c9: bson.ObjectId,
};

pub const Big = struct {
    id: ?bson.ObjectId = null,
    f0: bool,
    f1: i32,
    f2: i64,
    f3: u16,
    f4: u32,
    f5: f64,
    f6: []const u8,
    f7: Kind,
    f8: bson.DateTime,
    f9: bson.ObjectId,
    f10: ?[]const u8 = null,
    f11: ?i64 = null,
    f12: []const []const u8,
    f13: bson.Decimal128,
    f14: bson.Binary,
    f15: ?bool = null,
    f16: u8,
    f17: i16,
    f18: ?f64 = null,
    a: A,
    b: ?B = null,
    c: []const C = &.{},

    pub const odm_schema: odm.Schema(Big) = .{
        .collection = "big",
        .id = .id,
        .names = .{ .f0 = "fZero", .f1 = "fOne" },
        .indexes = &.{
            .{ .keys = &.{ .{ .f6 = .asc }, .{ .@"a.deep.d3" = .desc } } },
            .{ .keys = &.{.{ .@"c.c6" = .text }} },
            .{ .keys = &.{.{ .@"b.b6" = .asc }}, .unique = true, .sparse = true },
        },
    };
};

const id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;
const since: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };

/// `got` is the document `expected`, byte for byte.
fn expectDoc(arena: std.mem.Allocator, expected: anytype, got: bson.RawDocument) !void {
    const want = try bson.encode(arena, expected, .{});
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

test "big model: a find over twelve paths" {
    comptime odm.assertModel(Big);
    try testing.expectEqual(63, @typeInfo(odm.Path(Big)).@"enum".field_names.len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var min: i32 = 1;
    _ = &min;
    // Twelve paths: top-level fields of each kind, an item of a list,
    // paths into structs two levels deep, one item of a list of structs,
    // and two fields in a logical operator.
    const doc = try filter.encode(Big, arena.allocator(), .{
        .f1 = .{ .gte = min, .lt = 10 },
        .f6 = .{ .regex = "^a" },
        .f7 = .{ .in = .{ .one, .two } },
        .f9 = id,
        .f11 = null,
        .f12 = "x",
        .a = .{ .a4 = .{ .gt = 5 }, .deep = .{ .d6 = "y" } },
        .b = .{ .b2 = .{ .ne = 3 } },
        .c = .{ .elem_match = .{ .c1 = 2 } },
        .@"or" = .{ .{ .f3 = 1 }, .{ .f16 = .{ .exists = true } } },
    });
    try expectDoc(arena.allocator(), .{
        .fOne = .{ .@"$gte" = @as(i32, 1), .@"$lt" = @as(i32, 10) },
        .f6 = .{ .@"$regex" = "^a" },
        .f7 = .{ .@"$in" = .{ "one", "two" } },
        .f9 = id,
        .f11 = null,
        .f12 = "x",
        .@"a.a4" = .{ .@"$gt" = @as(i64, 5) },
        .@"a.deep.d6" = "y",
        .@"b.b2" = .{ .@"$ne" = @as(i64, 3) },
        .c = .{ .@"$elemMatch" = .{ .c1 = @as(i32, 2) } },
        .@"$or" = .{ .{ .f3 = @as(i32, 1) }, .{ .f16 = .{ .@"$exists" = true } } },
    }, doc);

    // The options of the find: a sort over paths two levels deep and
    // through a list of structs, and its counts.
    const find = try options.find(Big, .find, arena.allocator(), .{
        .sort = .{ .f2 = .desc, .a = .{ .deep = .{ .d1 = .asc } }, .c = .{ .c4 = .desc } },
        .skip = 5,
        .limit = 100,
        .batch_size = 50,
    });
    try expectDoc(arena.allocator(), .{ .f2 = @as(i32, -1), .@"a.deep.d1" = @as(i32, 1), .@"c.c4" = @as(i32, -1) }, find.sort.?);
    try testing.expectEqual(100, find.limit);

    // A projection with structs inside structs, an optional struct and a
    // list of structs.
    const View = struct {
        f6: []const u8,
        a: struct { deep: struct { d6: []const u8 } },
        b: ?struct { b9: bson.ObjectId },
        c: []const struct { c1: i32 },
    };
    const one: i32 = 1;
    try expectDoc(arena.allocator(), .{ .f6 = one, .@"a.deep.d6" = one, .@"b.b9" = one, .@"c.c1" = one, ._id = @as(i32, 0) }, try options.projection(Big, View, arena.allocator()));
}
