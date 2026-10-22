//! The 50-field model of the compile-time measurements (design §10, Р50):
//! 20 top-level fields of every kind, and three structs of 10 fields, one
//! of which holds a struct of 10, 63 paths in all. Its tests are named
//! "big model: …", so that a build can take them alone.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");

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

test "big model: a find over twelve paths" {
    comptime odm.assertModel(Big);
    try testing.expectEqual(63, @typeInfo(odm.Path(Big)).@"enum".field_names.len);
}
