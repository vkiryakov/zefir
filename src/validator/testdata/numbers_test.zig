//! The number rules on every field type they accept: integers of every width
//! at their boundaries, every float type with NaN, infinities, signed zeros
//! and subnormals, optionals, and numbers as list items.
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

test "positive has its documented code and default message" {
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

/// The integer types every number rule runs on, and the signed ones the sign
/// rules take.
const widths = .{ u8, i8, u64, i64, u128, i128, usize };
const signed_widths = .{ i8, i64, i128 };

fn decimal(comptime prefix: []const u8, comptime n: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{s}{d}", .{ prefix, n });
}

test "the number rules have their documented codes and default messages" {
    try h.expectRule(v.min(18), "validation.min", "must be at least 18");
    try h.expectRule(v.max(100), "validation.max", "must be at most 100");
    try h.expectRule(v.range(1, 10), "validation.range", "must be from 1 to 10");
    try h.expectRule(v.range(7, 7), "validation.range", "must be 7");
    try h.expectRule(v.nonNegative, "validation.non_negative", "must not be negative");
    try h.expectRule(v.negative, "validation.negative", "must be less than 0");
    try h.expectRule(v.nonPositive, "validation.non_positive", "must not be positive");
    try h.expectRule(v.divisibleBy(5), "validation.divisible_by", "must be divisible by 5");
    try h.expectRule(v.finite, "validation.finite", "must be a finite number");
}

test "min, max and range on every integer width: at, inside and outside each bound, minInt and maxInt" {
    inline for (widths) |T| {
        const lo = math.minInt(T);
        const hi = math.maxInt(T);
        const above_lowest = v.min(lo + 1);
        try h.expectFail(T, above_lowest, lo, "validation.min", comptime decimal("must be at least ", lo + 1));
        try h.expectPass(T, above_lowest, lo + 1);
        try h.expectPass(T, above_lowest, hi);
        try h.expectPass(T, v.min(hi), hi);
        try h.expectFail(T, v.min(hi), hi - 1, "validation.min", comptime decimal("must be at least ", hi));

        const below_highest = v.max(hi - 1);
        try h.expectFail(T, below_highest, hi, "validation.max", comptime decimal("must be at most ", hi - 1));
        try h.expectPass(T, below_highest, hi - 1);
        try h.expectPass(T, below_highest, lo);
        try h.expectPass(T, v.max(lo), lo);
        try h.expectFail(T, v.max(lo), lo + 1, "validation.max", comptime decimal("must be at most ", lo));

        const inner = v.range(lo + 1, hi - 1);
        const from_to = comptime std.fmt.comptimePrint("must be from {d} to {d}", .{ lo + 1, hi - 1 });
        try h.expectFail(T, inner, lo, "validation.range", from_to);
        try h.expectFail(T, inner, hi, "validation.range", from_to);
        try h.expectPass(T, inner, lo + 1);
        try h.expectPass(T, inner, hi - 1);
    }
}

test "range of one value accepts only it, and a typed bound converts to the field type" {
    try h.expectPass(i64, v.range(-3, -3), -3);
    try h.expectFail(i64, v.range(-3, -3), -2, "validation.range", "must be -3");
    try h.expectFail(i64, v.range(-3, -3), -4, "validation.range", "must be -3");
    try h.expectPass(i64, v.min(@as(u8, 5)), 5);
    try h.expectFail(i64, v.min(@as(u8, 5)), 4, "validation.min", "must be at least 5");
    try h.expectPass(f32, v.max(@as(f64, 0.5)), 0.5);
    try h.expectFail(f32, v.max(@as(f64, 0.5)), 0.75, "validation.max", "must be at most 0.5");
}

test "min, max and range on every float type: NaN and infinities report validation.finite, -0.0 equals 0, subnormals count" {
    inline for (floats) |F| {
        const tiny = math.floatTrueMin(F);
        const huge = math.floatMax(F);
        const negative_zero = -@as(F, 0.0);
        inline for (.{ math.nan(F), -math.nan(F), math.snan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.min(0), bad, finite_code, finite_message);
            try h.expectFail(F, v.max(0), bad, finite_code, finite_message);
            try h.expectFail(F, v.range(-1, 1), bad, finite_code, finite_message);
        }
        try h.expectPass(F, v.min(0), negative_zero);
        try h.expectPass(F, v.min(0), 0.0);
        try h.expectPass(F, v.min(0), tiny);
        try h.expectPass(F, v.min(0), huge);
        try h.expectFail(F, v.min(0), -tiny, "validation.min", "must be at least 0");
        try h.expectFail(F, v.min(0), -huge, "validation.min", "must be at least 0");

        try h.expectPass(F, v.max(-0.0), negative_zero);
        try h.expectPass(F, v.max(-0.0), 0.0);
        try h.expectPass(F, v.max(-0.0), -tiny);
        try h.expectFail(F, v.max(-0.0), tiny, "validation.max", "must be at most 0");

        try h.expectPass(F, v.range(-1, 1), -1);
        try h.expectPass(F, v.range(-1, 1), 1);
        try h.expectFail(F, v.range(-1, 1), math.nextAfter(F, 1, 2), "validation.range", "must be from -1 to 1");
        try h.expectFail(F, v.range(-1, 1), math.nextAfter(F, -1, -2), "validation.range", "must be from -1 to 1");

        try h.expectPass(F, v.min(0.5), 0.5);
        try h.expectFail(F, v.min(0.5), math.nextAfter(F, 0.5, 0), "validation.min", "must be at least 0.5");
    }
}

test "the number rules compare c_longdouble in its own width, whatever the target makes it" {
    const L = c_longdouble;
    const tiny = math.floatTrueMin(L);
    const huge = math.floatMax(L);
    // Wider than f64, tiny rounds to 0 and huge to inf in f64: rules that
    // compared in f64 would pass tiny under max(0) and report huge as not finite.
    try h.expectFail(L, v.max(0), tiny, "validation.max", "must be at most 0");
    try h.expectPass(L, v.min(1), huge);
    try h.expectFail(L, v.nonPositive, tiny, "validation.non_positive", "must not be positive");
    try h.expectPass(L, v.negative, -tiny);
    try h.expectFail(L, v.divisibleBy(1), tiny, "validation.divisible_by", "must be divisible by 1");
    try h.expectPass(L, v.divisibleBy(1), huge);
    try h.expectPass(L, v.finite, huge);
}

test "the sign rules on signed integers: minInt, -1, 0, 1 and maxInt" {
    inline for (signed_widths) |T| {
        const lo = math.minInt(T);
        const hi = math.maxInt(T);
        try h.expectPass(T, v.nonNegative, 0);
        try h.expectPass(T, v.nonNegative, hi);
        try h.expectFail(T, v.nonNegative, -1, "validation.non_negative", "must not be negative");
        try h.expectFail(T, v.nonNegative, lo, "validation.non_negative", "must not be negative");
        try h.expectPass(T, v.negative, -1);
        try h.expectPass(T, v.negative, lo);
        try h.expectFail(T, v.negative, 0, "validation.negative", "must be less than 0");
        try h.expectFail(T, v.negative, hi, "validation.negative", "must be less than 0");
        try h.expectPass(T, v.nonPositive, 0);
        try h.expectPass(T, v.nonPositive, lo);
        try h.expectFail(T, v.nonPositive, 1, "validation.non_positive", "must not be positive");
        try h.expectFail(T, v.nonPositive, hi, "validation.non_positive", "must not be positive");
    }
}

test "the sign rules on every float type: -0.0 is neither negative nor positive, the smallest subnormal is" {
    inline for (floats) |F| {
        const tiny = math.floatTrueMin(F);
        const huge = math.floatMax(F);
        const negative_zero = -@as(F, 0.0);
        inline for (.{ math.nan(F), -math.nan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.nonNegative, bad, finite_code, finite_message);
            try h.expectFail(F, v.negative, bad, finite_code, finite_message);
            try h.expectFail(F, v.nonPositive, bad, finite_code, finite_message);
        }
        try h.expectPass(F, v.nonNegative, negative_zero);
        try h.expectPass(F, v.nonNegative, tiny);
        try h.expectFail(F, v.nonNegative, -tiny, "validation.non_negative", "must not be negative");
        try h.expectFail(F, v.negative, negative_zero, "validation.negative", "must be less than 0");
        try h.expectFail(F, v.negative, tiny, "validation.negative", "must be less than 0");
        try h.expectPass(F, v.negative, -tiny);
        try h.expectPass(F, v.negative, -huge);
        try h.expectPass(F, v.nonPositive, negative_zero);
        try h.expectPass(F, v.nonPositive, -huge);
        try h.expectFail(F, v.nonPositive, tiny, "validation.non_positive", "must not be positive");
    }
}

test "divisibleBy on every integer width is exact, minInt and the largest divisors included" {
    inline for (widths) |T| {
        const hi = math.maxInt(T);
        try h.expectPass(T, v.divisibleBy(2), 0);
        try h.expectPass(T, v.divisibleBy(2), hi - 1);
        try h.expectFail(T, v.divisibleBy(2), hi, "validation.divisible_by", "must be divisible by 2");
        // maxInt(T) is the largest divisor of an unsigned type and divides itself.
        try h.expectPass(T, v.divisibleBy(hi), hi);
        try h.expectFail(T, v.divisibleBy(hi), hi - 1, "validation.divisible_by", comptime decimal("must be divisible by ", hi));
    }
    inline for (signed_widths) |T| {
        const lo = math.minInt(T);
        const hi = math.maxInt(T);
        try h.expectPass(T, v.divisibleBy(2), lo);
        try h.expectFail(T, v.divisibleBy(2), lo + 1, "validation.divisible_by", "must be divisible by 2");
        try h.expectPass(T, v.divisibleBy(hi), -hi);
        try h.expectFail(T, v.divisibleBy(hi), lo, "validation.divisible_by", comptime decimal("must be divisible by ", hi));
        // -minInt(T) is one past maxInt(T): only 0 and minInt(T) are its multiples.
        const top = v.divisibleBy(-lo);
        const top_message = comptime decimal("must be divisible by ", -lo);
        try h.expectPass(T, top, lo);
        try h.expectPass(T, top, 0);
        try h.expectFail(T, top, lo + 1, "validation.divisible_by", top_message);
        try h.expectFail(T, top, -1, "validation.divisible_by", top_message);
        try h.expectFail(T, top, 1, "validation.divisible_by", top_message);
        try h.expectFail(T, top, hi, "validation.divisible_by", top_message);
    }
    // Exact above 2^53, where a double would round: 9007199254740993 is 3 * 3002399751580331.
    try h.expectPass(u64, v.divisibleBy(3), 9007199254740993);
    try h.expectFail(u64, v.divisibleBy(3), 9007199254740994, "validation.divisible_by", "must be divisible by 3");
}

test "divisibleBy on every float type: divisibleBy(1) means a whole number; NaN and infinities report validation.finite" {
    inline for (floats) |F| {
        const tiny = math.floatTrueMin(F);
        const huge = math.floatMax(F);
        inline for (.{ math.nan(F), -math.nan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.divisibleBy(1), bad, finite_code, finite_message);
            try h.expectFail(F, v.divisibleBy(2), bad, finite_code, finite_message);
        }
        try h.expectPass(F, v.divisibleBy(1), -@as(F, 0.0));
        try h.expectPass(F, v.divisibleBy(1), -3);
        try h.expectPass(F, v.divisibleBy(1), huge);
        try h.expectPass(F, v.divisibleBy(1), -huge);
        try h.expectFail(F, v.divisibleBy(1), 0.5, "validation.divisible_by", "must be divisible by 1");
        try h.expectFail(F, v.divisibleBy(1), tiny, "validation.divisible_by", "must be divisible by 1");
        try h.expectPass(F, v.divisibleBy(2), -6);
        try h.expectFail(F, v.divisibleBy(2), 3, "validation.divisible_by", "must be divisible by 2");
        try h.expectFail(F, v.divisibleBy(2), 2.5, "validation.divisible_by", "must be divisible by 2");
    }
}

test "finite on every float type: only NaN and infinities fail, with its own code" {
    inline for (floats) |F| {
        inline for (.{ math.nan(F), -math.nan(F), math.snan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.finite, bad, finite_code, finite_message);
        }
        try h.expectPass(F, v.finite, -@as(F, 0.0));
        try h.expectPass(F, v.finite, math.floatTrueMin(F));
        try h.expectPass(F, v.finite, math.floatMax(F));
        try h.expectPass(F, v.finite, -math.floatMax(F));
    }
}

test "messages show bounds as written, while values are compared in the field type" {
    try h.expectFail(f32, v.max(0.1), 0.2, "validation.max", "must be at most 0.1");
    try h.expectPass(f32, v.max(0.1), 0.1);
    try h.expectFail(f32, v.max(0.1), math.nextAfter(f32, 0.1, 1), "validation.max", "must be at most 0.1");
    try h.expectFail(f32, v.min(-0.0), -1, "validation.min", "must be at least 0");
    try h.expectFail(f64, v.max(1e-6), 1e-5, "validation.max", "must be at most 0.000001");
    try h.expectFail(f64, v.max(9.99e-7), 1e-6, "validation.max", "must be at most 9.99e-7");
    try h.expectPass(f64, v.min(-math.floatMax(f64)), -math.floatMax(f64));
    try h.expectFail(f64, v.min(-math.floatMax(f64)), -math.inf(f64), finite_code, finite_message);
    try h.expectFail(f16, v.range(0.25, 0.75), 1, "validation.range", "must be from 0.25 to 0.75");
    try h.expectRule(v.max(math.maxInt(u128)), "validation.max", "must be at most 340282366920938463463374607431768211455");
}

test "a bound that f32 cannot hold is rounded to each wider float type: the neighbours on both sides decide" {
    inline for (.{ f64, f80, f128, c_longdouble }) |F| {
        const at_most = "must be at most 0.1";
        try h.expectPass(F, v.max(0.1), math.nextAfter(F, 0.1, 0));
        try h.expectPass(F, v.max(0.1), 0.1);
        try h.expectFail(F, v.max(0.1), math.nextAfter(F, 0.1, 1), "validation.max", at_most);
        const at_least = "must be at least 0.1";
        try h.expectFail(F, v.min(0.1), math.nextAfter(F, 0.1, 0), "validation.min", at_least);
        try h.expectPass(F, v.min(0.1), 0.1);
        try h.expectPass(F, v.min(0.1), math.nextAfter(F, 0.1, 1));
        const from_to = "must be from 0.1 to 0.2";
        try h.expectFail(F, v.range(0.1, 0.2), math.nextAfter(F, 0.1, 0), "validation.range", from_to);
        try h.expectPass(F, v.range(0.1, 0.2), 0.1);
        try h.expectPass(F, v.range(0.1, 0.2), math.nextAfter(F, 0.1, 1));
        try h.expectPass(F, v.range(0.1, 0.2), math.nextAfter(F, 0.2, 0));
        try h.expectPass(F, v.range(0.1, 0.2), 0.2);
        try h.expectFail(F, v.range(0.1, 0.2), math.nextAfter(F, 0.2, 1), "validation.range", from_to);
    }
}

test "a bound beyond the range of f64 keeps its value on f80 and f128 fields" {
    inline for (.{ f80, f128 }) |F| {
        try h.expectPass(F, v.max(1e400), 1e400);
        try h.expectFail(F, v.max(1e400), math.nextAfter(F, 1e400, math.inf(F)), "validation.max", "must be at most 1e400");
        try h.expectPass(F, v.min(1e-400), 1e-400);
        try h.expectFail(F, v.min(1e-400), math.nextAfter(F, 1e-400, 0), "validation.min", "must be at least 1e-400");
    }
}

test "the number rules on ?T and ??T: null skips them" {
    try h.expectPass(?i64, v.min(0), null);
    try h.expectFail(?i64, v.min(0), -1, "validation.min", "must be at least 0");
    try h.expectPass(??u8, v.max(9), null);
    try h.expectPass(??u8, v.max(9), @as(?u8, null));
    try h.expectFail(??u8, v.max(9), @as(?u8, 10), "validation.max", "must be at most 9");
    try h.expectPass(?f32, v.range(0, 1), null);
    try h.expectFail(?f32, v.range(0, 1), math.nan(f32), finite_code, finite_message);
    try h.expectPass(?i8, v.negative, null);
    try h.expectFail(??i128, v.nonPositive, @as(?i128, 1), "validation.non_positive", "must not be positive");
    try h.expectFail(?f80, v.nonNegative, -1, "validation.non_negative", "must not be negative");
    try h.expectFail(?u32, v.divisibleBy(4), 6, "validation.divisible_by", "must be divisible by 4");
    try h.expectPass(?f64, v.finite, null);
    try h.expectFail(??f64, v.finite, @as(?f64, math.inf(f64)), finite_code, finite_message);
}

test "the number rules inside each: slices, arrays, optional items and nested lists" {
    const Dto = struct {
        scores: []const u16 = &.{},
        grid: [2][2]i16 = .{ .{ 0, 0 }, .{ 0, 0 } },
        maybe: []const ?f64 = &.{},
        steps: [3]u32 = .{ 5, 10, 15 },
        limits: []const i32 = &.{},
        deltas: [2]f32 = .{ -1, -2 },
        pub const field_rules = .{
            .scores = v.each(v.range(1, 10)),
            .grid = v.each(v.each(v.nonPositive)),
            .maybe = v.each(.{ v.finite, v.min(0.5) }),
            .steps = v.each(v.divisibleBy(5)),
            .limits = v.each(.{ v.nonNegative, v.max(100) }),
            .deltas = v.each(v.negative),
        };
    };
    try h.expectValid(&Dto{ .scores = &.{ 1, 10 }, .maybe = &.{ null, 0.5 }, .limits = &.{ 0, 100 } });
    try h.expectAt(&Dto{ .scores = &.{ 1, 11 } }, "validation.range", "must be from 1 to 10", "scores[1]");
    try h.expectAt(&Dto{ .grid = .{ .{ 0, -1 }, .{ 0, 1 } } }, "validation.non_positive", "must not be positive", "grid[1][1]");
    try h.expectAt(&Dto{ .maybe = &.{ null, math.inf(f64) } }, finite_code, finite_message, "maybe[1]");
    try h.expectAt(&Dto{ .maybe = &.{0.25} }, "validation.min", "must be at least 0.5", "maybe[0]");
    try h.expectAt(&Dto{ .steps = .{ 5, 7, 15 } }, "validation.divisible_by", "must be divisible by 5", "steps[1]");
    try h.expectAt(&Dto{ .limits = &.{ 0, -1 } }, "validation.non_negative", "must not be negative", "limits[1]");
    try h.expectAt(&Dto{ .limits = &.{101} }, "validation.max", "must be at most 100", "limits[0]");
    try h.expectAt(&Dto{ .deltas = .{ -1, -0.0 } }, "validation.negative", "must be less than 0", "deltas[1]");
    try h.expectAll(&Dto{ .scores = &.{ 0, 5, 11 }, .maybe = &.{ math.nan(f64), 0.1 } }, &.{
        .{ .code = "validation.range", .field = "scores[0]" },
        .{ .code = "validation.range", .field = "scores[2]" },
        .{ .code = finite_code, .field = "maybe[0]" },
        .{ .code = "validation.min", .field = "maybe[1]" },
    });
}

test "number rules run left to right: the first one that fails is the value's only violation" {
    try h.expectFail(f64, .{ v.finite, v.min(0), v.max(10) }, math.nan(f64), finite_code, finite_message);
    try h.expectFail(f64, .{ v.min(0), v.max(10) }, -math.inf(f64), finite_code, finite_message);
    try h.expectFail(i32, .{ v.min(0), v.divisibleBy(2) }, -3, "validation.min", "must be at least 0");
    try h.expectFail(i32, .{ v.min(0), v.divisibleBy(2) }, 3, "validation.divisible_by", "must be divisible by 2");
    try h.expectPass(i32, .{ v.min(0), v.divisibleBy(2) }, 4);
}
