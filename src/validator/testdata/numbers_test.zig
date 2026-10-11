//! `v.positive` on every field type it accepts: integers of every width at
//! their boundaries, every float type with NaN, infinities, signed zeros and
//! subnormals, optionals, and numbers as list items.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const math = std.math;
const testing = std.testing;

const code = "validation.positive";
const message = "must be greater than 0";
const finite_code = "validation.finite";
const finite_message = "must be a finite number";

const ints = .{ u8, i8, u16, i16, u32, i32, u64, i64, u128, i128, usize, isize };
const signed_ints = .{ i8, i16, i32, i64, i128, isize };
const floats = .{ f16, f32, f64, f80, f128, c_longdouble };

test "positive has the catalog code and default message" {
    try h.expectRule(v.positive, code, message);
}

test "positive on every integer width: 1 and maxInt pass, 0, -1 and minInt fail" {
    inline for (ints) |T| {
        try h.expectFail(T, v.positive, 0, code, message);
        try h.expectPass(T, v.positive, 1);
        try h.expectPass(T, v.positive, math.maxInt(T));
    }
    inline for (signed_ints) |T| {
        try h.expectFail(T, v.positive, -1, code, message);
        try h.expectFail(T, v.positive, math.minInt(T), code, message);
    }
}

test "positive on every float type: NaN and infinities report validation.finite, both zeros fail, the smallest subnormal passes" {
    inline for (floats) |F| {
        inline for (.{ math.nan(F), -math.nan(F), math.snan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.positive, bad, finite_code, finite_message);
        }
        const negative_zero = -@as(F, 0.0);
        try testing.expect(math.signbit(negative_zero));
        try h.expectFail(F, v.positive, negative_zero, code, message);
        try h.expectFail(F, v.positive, 0.0, code, message);
        try h.expectFail(F, v.positive, -math.floatTrueMin(F), code, message);
        try h.expectFail(F, v.positive, -math.floatMax(F), code, message);
        try h.expectPass(F, v.positive, math.floatTrueMin(F));
        try h.expectPass(F, v.positive, math.floatMin(F));
        try h.expectPass(F, v.positive, 1);
        try h.expectPass(F, v.positive, math.floatMax(F));
    }
}

test "positive compares c_longdouble in its own width, whatever the target makes it" {
    const L = c_longdouble;
    // The float type of the same width: f64, f80 or f128 depending on the target.
    const Same = std.meta.Float(@bitSizeOf(L));
    const tiny = math.floatTrueMin(L);
    const huge = math.floatMax(L);
    try testing.expectEqual(@as(L, @floatCast(math.floatTrueMin(Same))), tiny);
    try testing.expectEqual(@as(L, @floatCast(math.floatMax(Same))), huge);
    try h.expectPass(L, v.positive, tiny);
    try h.expectPass(L, v.positive, huge);
    // Wider than f64, the smallest subnormal rounds to 0 and the largest finite
    // value to inf in f64: a rule that compared in f64 would reject tiny with
    // validation.positive and huge with validation.finite.
    const wider = @bitSizeOf(L) > 64;
    try testing.expectEqual(wider, @as(f64, @floatCast(tiny)) == 0);
    try testing.expectEqual(wider, math.isInf(@as(f64, @floatCast(huge))));
}

test "positive on ?T and ??T: null skips the rule" {
    try h.expectPass(?u32, v.positive, null);
    try h.expectFail(?u32, v.positive, 0, code, message);
    try h.expectPass(?u32, v.positive, 7);
    try h.expectPass(??i64, v.positive, null);
    try h.expectPass(??i64, v.positive, @as(?i64, null));
    try h.expectFail(??i64, v.positive, @as(?i64, -5), code, message);
    try h.expectPass(??i64, v.positive, @as(?i64, 5));
    try h.expectPass(?f64, v.positive, null);
    try h.expectFail(?f64, v.positive, math.nan(f64), finite_code, finite_message);
    try h.expectFail(??f32, v.positive, @as(?f32, -0.0), code, message);
}

test "positive inside each: slices, arrays, optional items and nested lists" {
    const Dto = struct {
        ids: []const u64 = &.{},
        grid: [2][2]i16 = .{ .{ 1, 1 }, .{ 1, 1 } },
        maybe: []const ?u32 = &.{},
        prices: []const f32 = &.{},
        pub const field_rules = .{
            .ids = v.each(v.positive),
            .grid = v.each(v.each(v.positive)),
            .maybe = v.each(v.positive),
            .prices = v.each(v.positive),
        };
    };
    try h.expectValid(&Dto{ .ids = &.{ 1, math.maxInt(u64) }, .maybe = &.{ null, 1 }, .prices = &.{ 0.5, math.floatTrueMin(f32) } });
    try h.expectAt(&Dto{ .ids = &.{ 1, 0 } }, code, message, "ids[1]");
    try h.expectAt(&Dto{ .grid = .{ .{ 1, 1 }, .{ 1, -1 } } }, code, message, "grid[1][1]");
    try h.expectAt(&Dto{ .maybe = &.{ null, 0 } }, code, message, "maybe[1]");
    try h.expectAt(&Dto{ .prices = &.{ 1, math.inf(f32) } }, finite_code, finite_message, "prices[1]");
    try h.expectAll(&Dto{ .ids = &.{ 0, 1, 0 }, .prices = &.{ math.nan(f32), -0.0 } }, &.{
        .{ .code = code, .field = "ids[0]" },
        .{ .code = code, .field = "ids[2]" },
        .{ .code = finite_code, .field = "prices[0]" },
        .{ .code = code, .field = "prices[1]" },
    });
}
