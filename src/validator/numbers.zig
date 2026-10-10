//! Number rules: `positive`. On a float field NaN, +inf and -inf fail every
//! number rule with the precondition `validation.finite` / "must be a finite
//! number".
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

fn acceptsNumber(comptime T: type) bool {
    return core.isNumber(T);
}

/// `value > 0` on integers of any width and signedness and on floats: -0.0
/// fails, the smallest subnormal passes.
pub const positive: Rule = core.define(.positive, .{
    .message = "must be greater than 0",
    .precondition = core.preconditions.finite,
    .fits = struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (!core.isNumber(T)) core.typeError(rule, T, where, "a number", acceptsNumber, null);
        }
    }.fits,
    .eval = signEval(.gt),
});

/// The run-time check of a sign rule: `value <op> 0`, after the finite
/// precondition on floats.
fn signEval(comptime op: std.math.CompareOperator) fn (anytype) Outcome {
    return struct {
        fn eval(value: anytype) Outcome {
            const T = @TypeOf(value.*);
            if (comptime core.isFloat(T)) {
                if (!std.math.isFinite(value.*)) return .precondition;
            }
            return core.passIf(std.math.compare(value.*, op, 0));
        }
    }.eval;
}

fn expectOutcome(expected: Outcome, comptime rule: Rule, value: anytype) !void {
    try std.testing.expectEqual(expected, rule.eval(&value));
}

test "positive has the catalog code and message and the finite precondition" {
    try std.testing.expectEqualStrings("validation.positive", positive.code);
    try std.testing.expectEqualStrings("must be greater than 0", positive.message);
    try std.testing.expectEqual(core.Kind.positive, positive.kind);
    try std.testing.expectEqual(null, positive.args);
    try std.testing.expectEqualStrings("validation.finite", positive.precondition.?.code);
    try std.testing.expectEqualStrings("must be a finite number", positive.precondition.?.message);
}

test "positive on integers passes above 0 only" {
    try expectOutcome(.fail, positive, @as(u8, 0));
    try expectOutcome(.pass, positive, @as(u8, 1));
    try expectOutcome(.fail, positive, @as(i64, std.math.minInt(i64)));
    try expectOutcome(.fail, positive, @as(i64, -1));
    try expectOutcome(.fail, positive, @as(i64, 0));
    try expectOutcome(.pass, positive, @as(i64, std.math.maxInt(i64)));
    try expectOutcome(.pass, positive, @as(u64, std.math.maxInt(u64)));
}

test "positive on floats: -0.0 and 0.0 fail, the smallest subnormal passes" {
    try expectOutcome(.fail, positive, @as(f64, -0.0));
    try expectOutcome(.fail, positive, @as(f64, 0.0));
    try expectOutcome(.pass, positive, @as(f64, @bitCast(@as(u64, 1))));
    try expectOutcome(.fail, positive, -@as(f64, @bitCast(@as(u64, 1))));
    try expectOutcome(.pass, positive, std.math.floatTrueMin(f32));
}

test "positive reports the precondition on NaN and infinities" {
    try expectOutcome(.precondition, positive, std.math.nan(f64));
    try expectOutcome(.precondition, positive, std.math.inf(f64));
    try expectOutcome(.precondition, positive, -std.math.inf(f64));
}

test "positive fits integers and floats" {
    comptime {
        for ([_]type{ u8, i8, u64, i64, u128, i128, usize, f16, f32, f64, f80, f128, c_longdouble }) |T| {
            positive.fits(&positive, T, "Dto.field_rules.x");
        }
    }
}
