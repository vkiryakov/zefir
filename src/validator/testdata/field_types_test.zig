//! The rules on the field types they accept, as the walker meets them: as
//! `?T` and `??T` (null at either level skips the rule), as an item of
//! `[]const T`, `[]T`, `[N]T` and `[]const ?T` through `each` (a null item
//! is skipped and keeps its index), and as an item of a nested list through
//! `each(each(...))`, with one type of each kind a rule accepts. `notEmpty`,
//! `positive`, `each` and `custom` have these cases in their own files.
//! common_test.zig, numbers_test.zig and lists_test.zig run the rules on
//! every plain type with its edge values; this file adds the plain types
//! they leave out, and the finite precondition under `withMessage` for the
//! rules that messages_test.zig does not show it on.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const math = std.math;

const Role = enum { admin, user, guest };
const Open = enum(u8) { a, b, _ };
const OpenOne = enum(u8) { only, _ };
const Only = enum { only };
const Sparse = enum(u32) { low = 1, high = 1_000_000 };

const equals_code = "validation.equals";
const not_equals_code = "validation.not_equals";
const one_of_code = "validation.one_of";
const none_of_code = "validation.none_of";
const empty_code = "validation.empty";
const finite_code = "validation.finite";
const finite_message = "must be a finite number";

/// `rule` on `T` through every wrapper the walker unwraps: `?T` and `??T`
/// (null at either level skips it), an item of `[]const T`, `[]T`, `[2]T`
/// and `[]const ?T` through `each` (null items are skipped), and an item of
/// `[]const []const T` through `each(each(...))`. `good` passes everywhere;
/// `bad` fails with `code` and `message` at the field or at its index. `T`
/// is not `u8`: a slice of `u8` is a string, not a list.
fn expectWrapped(comptime T: type, comptime rule: v.Rule, good: T, bad: T, code: []const u8, message: []const u8) !void {
    try h.expectPass(?T, rule, null);
    try h.expectPass(?T, rule, good);
    try h.expectFail(?T, rule, bad, code, message);
    try h.expectPass(??T, rule, null);
    try h.expectPass(??T, rule, @as(?T, null));
    try h.expectPass(??T, rule, @as(?T, good));
    try h.expectFail(??T, rule, @as(?T, bad), code, message);

    const Slice = h.One([]const T, v.each(rule));
    try h.expectValid(&Slice{ .x = &.{ good, good } });
    try h.expectAt(&Slice{ .x = &.{ good, bad } }, code, message, "x[1]");

    const Mutable = h.One([]T, v.each(rule));
    var items = [_]T{ bad, good };
    try h.expectAt(&Mutable{ .x = &items }, code, message, "x[0]");
    items[0] = good;
    try h.expectValid(&Mutable{ .x = &items });

    const Array = h.One([2]T, v.each(rule));
    try h.expectValid(&Array{ .x = .{ good, good } });
    try h.expectAt(&Array{ .x = .{ good, bad } }, code, message, "x[1]");

    const Maybe = h.One([]const ?T, v.each(rule));
    try h.expectValid(&Maybe{ .x = &.{ null, good, null } });
    try h.expectAt(&Maybe{ .x = &.{ null, null, bad } }, code, message, "x[2]");

    const Nested = h.One([]const []const T, v.each(v.each(rule)));
    try h.expectValid(&Nested{ .x = &.{ &.{}, &.{ good, good } } });
    try h.expectAt(&Nested{ .x = &.{ &.{good}, &.{ good, bad } } }, code, message, "x[1][1]");
}

test "equals and notEquals on ?T, ??T and as items of every kind of list: integers, floats, bools, enums and strings" {
    try expectWrapped(u64, v.equals(7), 7, 8, equals_code, "must be equal to 7");
    try expectWrapped(f16, v.equals(0.5), 0.5, 1.5, equals_code, "must be equal to 0.5");
    try expectWrapped(bool, v.equals(true), true, false, equals_code, "must be equal to true");
    try expectWrapped(Role, v.equals(.admin), .admin, .user, equals_code, "must be equal to admin");
    try expectWrapped([]const u8, v.equals("admin"), "admin", "root", equals_code, "must be equal to admin");
    try expectWrapped(i8, v.notEquals(0), -1, 0, not_equals_code, "must not be equal to 0");
    try expectWrapped(f32, v.notEquals(0), 1, 0, not_equals_code, "must not be equal to 0");
    try expectWrapped(bool, v.notEquals(false), true, false, not_equals_code, "must not be equal to false");
    try expectWrapped(Sparse, v.notEquals(.high), .low, .high, not_equals_code, "must not be equal to high");
    try expectWrapped([]const u8, v.notEquals("root"), "alice", "root", not_equals_code, "must not be equal to root");
}

test "oneOf and noneOf on ?T, ??T and as items of every kind of list, with the values as a tuple or an array" {
    try expectWrapped([]const u8, v.oneOf(.{ "a", "b" }), "b", "c", one_of_code, "must be one of: a, b");
    try expectWrapped(Role, v.oneOf([_]Role{ .admin, .user }), .user, .guest, one_of_code, "must be one of: admin, user");
    try expectWrapped(u64, v.oneOf([_]u64{ 1, 2 }), 2, 3, one_of_code, "must be one of: 1, 2");
    try expectWrapped([]const u8, v.noneOf([_][]const u8{ "root", "admin" }), "alice", "admin", none_of_code, "must not be one of: root, admin");
    try expectWrapped(Open, v.noneOf(.{.a}), .b, .a, none_of_code, "must not be a");
    try expectWrapped(i64, v.noneOf(.{ 0, 13 }), 7, 13, none_of_code, "must not be one of: 0, 13");
}

test "empty, minItems and maxItems on ?T, ??T and as the inner lists of every kind of list" {
    try expectWrapped([]const u8, v.empty, "", "a", empty_code, "must be empty");
    try expectWrapped([]const u32, v.empty, &.{}, &.{7}, empty_code, "must be empty");
    try expectWrapped([]const u32, v.minItems(2), &.{ 1, 2 }, &.{1}, "validation.min_items", "must have at least 2 items");
    try expectWrapped([]const []const u8, v.maxItems(1), &.{"a"}, &.{ "a", "b" }, "validation.max_items", "must have at most 1 item");
}

test "empty, minItems and maxItems count the items of a list of floats and never check them, NaN and inf included" {
    const odd: []const f64 = &.{ math.nan(f64), math.inf(f64) };
    try h.expectFail([]const f64, v.empty, odd, empty_code, "must be empty");
    try h.expectPass([]const f64, v.minItems(2), odd);
    try h.expectPass([]const f64, v.maxItems(2), odd);
    try h.expectFail([]const f64, v.maxItems(1), odd, "validation.max_items", "must have at most 1 item");
}

test "min, max and range on ?T, ??T and as items of every kind of list" {
    try expectWrapped(u128, v.min(10), 10, 9, "validation.min", "must be at least 10");
    try expectWrapped(f64, v.min(0.5), 0.5, 0.25, "validation.min", "must be at least 0.5");
    try expectWrapped(i128, v.max(-5), -5, -4, "validation.max", "must be at most -5");
    try expectWrapped(f80, v.max(2), 2, 3, "validation.max", "must be at most 2");
    try expectWrapped(usize, v.range(1, 3), 3, 4, "validation.range", "must be from 1 to 3");
    try expectWrapped(f128, v.range(-1, 1), -1, -2, "validation.range", "must be from -1 to 1");
}

test "nonNegative, negative, nonPositive, divisibleBy and finite on ?T, ??T and as items of every kind of list" {
    try expectWrapped(i8, v.nonNegative, 0, -1, "validation.non_negative", "must not be negative");
    try expectWrapped(c_longdouble, v.nonNegative, 0, -0.5, "validation.non_negative", "must not be negative");
    try expectWrapped(i64, v.negative, -1, 0, "validation.negative", "must be less than 0");
    try expectWrapped(f16, v.negative, -1, 0, "validation.negative", "must be less than 0");
    try expectWrapped(i128, v.nonPositive, 0, 1, "validation.non_positive", "must not be positive");
    try expectWrapped(f32, v.nonPositive, -0.0, 1, "validation.non_positive", "must not be positive");
    try expectWrapped(i64, v.divisibleBy(3), -9, 10, "validation.divisible_by", "must be divisible by 3");
    try expectWrapped(f64, v.divisibleBy(2), -4, 3, "validation.divisible_by", "must be divisible by 2");
    try expectWrapped(f80, v.finite, 1, math.inf(f80), finite_code, finite_message);
    // On a float item, the rules with the finite precondition report it at the item's index.
    const Prices = h.One([]const ?f32, v.each(v.min(0)));
    try h.expectAt(&Prices{ .x = &.{ null, 1, math.nan(f32) } }, finite_code, finite_message, "x[2]");
}

test "notEquals and noneOf compare mutable and sentinel-terminated strings like the other string kinds" {
    var root = "root".*;
    var alice = "alice".*;
    try h.expectFail([]u8, v.notEquals("root"), &root, not_equals_code, "must not be equal to root");
    try h.expectPass([]u8, v.notEquals("root"), &alice);
    try h.expectFail([]u8, v.noneOf(.{ "root", "admin" }), &root, none_of_code, "must not be one of: root, admin");
    try h.expectPass([]u8, v.noneOf(.{ "root", "admin" }), &alice);
    var root_z = [_:0]u8{ 'r', 'o', 'o', 't' };
    var alice_z = [_:0]u8{ 'a', 'l', 'i', 'c', 'e' };
    try h.expectFail([:0]u8, v.notEquals("root"), &root_z, not_equals_code, "must not be equal to root");
    try h.expectPass([:0]u8, v.notEquals("root"), &alice_z);
    try h.expectFail([:0]u8, v.noneOf(.{ "root", "admin" }), &root_z, none_of_code, "must not be one of: root, admin");
    try h.expectPass([:0]u8, v.noneOf(.{ "root", "admin" }), &alice_z);
}

test "oneOf on enums of one tag, noneOf on sparse tag values, and noneOf with an array of values" {
    // An exhaustive enum of one tag may list it: the rule then always passes.
    try h.expectPass(Only, v.oneOf(.{.only}), .only);
    try h.expectPass(OpenOne, v.oneOf(.{.only}), .only);
    try h.expectFail(OpenOne, v.oneOf(.{.only}), @fromBackingInt(5), one_of_code, "must be only");
    try h.expectFail(Sparse, v.noneOf(.{.high}), .high, none_of_code, "must not be high");
    try h.expectPass(Sparse, v.noneOf(.{.high}), .low);
    const reserved = [_][]const u8{ "root", "admin" };
    try h.expectFail([]const u8, v.noneOf(reserved), "admin", none_of_code, "must not be one of: root, admin");
    try h.expectPass([]const u8, v.noneOf(reserved), "alice");
    try h.expectFail(Role, v.noneOf([_]Role{.guest}), .guest, none_of_code, "must not be guest");
    try h.expectPass(Role, v.noneOf([_]Role{.guest}), .user);
    try h.expectFail(i64, v.noneOf([_]i64{ -1, 0 }), 0, none_of_code, "must not be one of: -1, 0");
    try h.expectPass(i64, v.noneOf([_]i64{ -1, 0 }), 1);
}

test "max, negative and nonPositive keep the finite precondition under withMessage on every float type" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try h.expectFail(F, v.max(10).withMessage("too big"), math.inf(F), finite_code, finite_message);
        try h.expectFail(F, v.max(10).withMessage("too big"), 11, "validation.max", "too big");
        try h.expectFail(F, v.negative.withMessage("must be below zero"), math.nan(F), finite_code, finite_message);
        try h.expectFail(F, v.negative.withMessage("must be below zero"), 0, "validation.negative", "must be below zero");
        try h.expectFail(F, v.nonPositive.withMessage("must be zero or less"), -math.inf(F), finite_code, finite_message);
        try h.expectFail(F, v.nonPositive.withMessage("must be zero or less"), 1, "validation.non_positive", "must be zero or less");
    }
}
