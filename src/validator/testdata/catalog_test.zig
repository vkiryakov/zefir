//! Catalog conformance of the shipped rules: each rule is exported under its
//! catalog name in its catalog form (a rule value or a constructor) with the
//! catalog code and default message, a rule with a precondition reports the
//! catalog precondition code and message, every rule the module exports has
//! a test here, the module exports exactly the catalog predicates of the
//! shipped rules, and the limits have their catalog values.
//! Placeholders are not checked yet: `withMessage`, which substitutes them,
//! is not shipped.
//!
//! In the repository, this file is the source of truth for the contract of
//! the shipped rules. It is generated from the rule catalog, which the
//! maintainer keeps outside the repository together with its generator
//! script: the maintainer regenerates the file when preparing a rule PR. A
//! contributor without the catalog edits it by hand, in the same change as
//! the rule. Any change to this file changes the contract of a rule.

const std = @import("std");
const v = @import("validator");
const testing = std.testing;

/// A DTO with one field `x` of type `T` and the given rules.
fn One(comptime T: type, comptime rules: anytype) type {
    return struct {
        x: T,
        pub const field_rules = .{ .x = rules };
    };
}

/// `v.check` on `.{ .x = value }` reports exactly this violation.
fn expectViolation(comptime T: type, comptime rules: anytype, value: T, code: []const u8, message: []const u8, field: []const u8) !void {
    const dto: One(T, rules) = .{ .x = value };
    var path_buf: [64]u8 = undefined;
    const violation = v.check(&dto, &path_buf) orelse return error.TestExpectedViolation;
    try testing.expectEqualStrings(code, violation.code);
    try testing.expectEqualStrings(message, violation.message);
    try testing.expectEqualStrings(field, violation.field orelse return error.TestExpectedField);
}

/// `v.check` on `.{ .x = value }` reports nothing.
fn expectNoViolation(comptime T: type, comptime rules: anytype, value: T) !void {
    const dto: One(T, rules) = .{ .x = value };
    var path_buf: [64]u8 = undefined;
    if (v.check(&dto, &path_buf)) |violation| {
        std.debug.print("unexpected violation {s}: {s}\n", .{ violation.code, violation.message });
        return error.TestUnexpectedViolation;
    }
}

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

test "equals is a rule constructor with code validation.equals and message \"must be equal to {expected}\", or \"must be equal to the expected value\" when that would be longer than 512 bytes" {
    try testing.expect(@hasDecl(v, "equals"));
    try testing.expect(@typeInfo(@TypeOf(v.equals)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.equals", v.equals(true).code);
    try testing.expectEqualStrings("must be equal to true", v.equals(true).message);
    const long = &@as([600]u8, @splat('x'));
    try testing.expectEqualStrings("validation.equals", v.equals(long).code);
    try testing.expectEqualStrings("must be equal to the expected value", v.equals(long).message);
    try expectViolation(bool, v.equals(true), false, "validation.equals", "must be equal to true", "x");
    try expectViolation([]const u8, v.equals(long), "x", "validation.equals", "must be equal to the expected value", "x");
    try expectNoViolation(bool, v.equals(true), true);
}

test "notEquals is a rule constructor with code validation.not_equals and message \"must not be equal to {forbidden}\", or \"must not be equal to the forbidden value\" when that would be longer than 512 bytes" {
    try testing.expect(@hasDecl(v, "notEquals"));
    try testing.expect(@typeInfo(@TypeOf(v.notEquals)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.not_equals", v.notEquals(0).code);
    try testing.expectEqualStrings("must not be equal to 0", v.notEquals(0).message);
    const long = &@as([600]u8, @splat('x'));
    try testing.expectEqualStrings("validation.not_equals", v.notEquals(long).code);
    try testing.expectEqualStrings("must not be equal to the forbidden value", v.notEquals(long).message);
    try expectViolation(i32, v.notEquals(0), 0, "validation.not_equals", "must not be equal to 0", "x");
    try expectViolation([]const u8, v.notEquals(long), long, "validation.not_equals", "must not be equal to the forbidden value", "x");
    try expectNoViolation(i32, v.notEquals(0), 1);
}

test "oneOf is a rule constructor with code validation.one_of and message \"must be one of: {values}\", \"must be {values}\" for one value, or \"must be one of the allowed values\" when that would be longer than 512 bytes" {
    try testing.expect(@hasDecl(v, "oneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.oneOf)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.one_of", v.oneOf(.{ "a", "b" }).code);
    try testing.expectEqualStrings("must be one of: a, b", v.oneOf(.{ "a", "b" }).message);
    try testing.expectEqualStrings("must be admin", v.oneOf(.{.admin}).message);
    const long = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };
    try testing.expectEqualStrings("validation.one_of", v.oneOf(long).code);
    try testing.expectEqualStrings("must be one of the allowed values", v.oneOf(long).message);
    try expectViolation([]const u8, v.oneOf(.{ "a", "b" }), "c", "validation.one_of", "must be one of: a, b", "x");
    try expectViolation([]const u8, v.oneOf(long), "c", "validation.one_of", "must be one of the allowed values", "x");
    try expectNoViolation([]const u8, v.oneOf(.{ "a", "b" }), "b");
}

test "noneOf is a rule constructor with code validation.none_of and message \"must not be one of: {values}\", \"must not be {values}\" for one value, or \"must not be one of the forbidden values\" when that would be longer than 512 bytes" {
    try testing.expect(@hasDecl(v, "noneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.noneOf)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.none_of", v.noneOf(.{ "a", "b" }).code);
    try testing.expectEqualStrings("must not be one of: a, b", v.noneOf(.{ "a", "b" }).message);
    try testing.expectEqualStrings("must not be admin", v.noneOf(.{.admin}).message);
    const long = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };
    try testing.expectEqualStrings("validation.none_of", v.noneOf(long).code);
    try testing.expectEqualStrings("must not be one of the forbidden values", v.noneOf(long).message);
    try expectViolation([]const u8, v.noneOf(.{ "a", "b" }), "a", "validation.none_of", "must not be one of: a, b", "x");
    try expectViolation([]const u8, v.noneOf(long), long[0], "validation.none_of", "must not be one of the forbidden values", "x");
    try expectNoViolation([]const u8, v.noneOf(.{ "a", "b" }), "c");
}

test "empty is a rule value with code validation.empty and message \"must be empty\"" {
    try testing.expect(@hasDecl(v, "empty"));
    try testing.expect(@TypeOf(v.empty) == v.Rule);
    try testing.expectEqualStrings("validation.empty", v.empty.code);
    try testing.expectEqualStrings("must be empty", v.empty.message);
    try expectViolation([]const u8, v.empty, "a", "validation.empty", "must be empty", "x");
    try expectNoViolation([]const u8, v.empty, "");
}

test "notEmpty is a rule value with code validation.not_empty and message \"must not be empty\"" {
    try testing.expect(@hasDecl(v, "notEmpty"));
    try testing.expect(@TypeOf(v.notEmpty) == v.Rule);
    try testing.expectEqualStrings("validation.not_empty", v.notEmpty.code);
    try testing.expectEqualStrings("must not be empty", v.notEmpty.message);
}

test "min is a rule constructor with code validation.min and message \"must be at least {min}\"" {
    try testing.expect(@hasDecl(v, "min"));
    try testing.expect(@typeInfo(@TypeOf(v.min)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.min", v.min(18).code);
    try testing.expectEqualStrings("must be at least 18", v.min(18).message);
    try expectViolation(u8, v.min(18), 17, "validation.min", "must be at least 18", "x");
    try expectNoViolation(u8, v.min(18), 18);
}

test "max is a rule constructor with code validation.max and message \"must be at most {max}\"" {
    try testing.expect(@hasDecl(v, "max"));
    try testing.expect(@typeInfo(@TypeOf(v.max)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.max", v.max(100).code);
    try testing.expectEqualStrings("must be at most 100", v.max(100).message);
    try expectViolation(u8, v.max(100), 101, "validation.max", "must be at most 100", "x");
    try expectNoViolation(u8, v.max(100), 100);
}

test "range is a rule constructor with code validation.range and message \"must be from {min} to {max}\", or \"must be {min}\" when min = max" {
    try testing.expect(@hasDecl(v, "range"));
    try testing.expect(@typeInfo(@TypeOf(v.range)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.range", v.range(1, 10).code);
    try testing.expectEqualStrings("must be from 1 to 10", v.range(1, 10).message);
    try testing.expectEqualStrings("validation.range", v.range(7, 7).code);
    try testing.expectEqualStrings("must be 7", v.range(7, 7).message);
    try expectViolation(i32, v.range(1, 10), 11, "validation.range", "must be from 1 to 10", "x");
    try expectViolation(i32, v.range(7, 7), 6, "validation.range", "must be 7", "x");
    try expectNoViolation(i32, v.range(1, 10), 1);
}

test "positive is a rule value with code validation.positive and message \"must be greater than 0\"" {
    try testing.expect(@hasDecl(v, "positive"));
    try testing.expect(@TypeOf(v.positive) == v.Rule);
    try testing.expectEqualStrings("validation.positive", v.positive.code);
    try testing.expectEqualStrings("must be greater than 0", v.positive.message);
}

test "nonNegative is a rule value with code validation.non_negative and message \"must not be negative\"" {
    try testing.expect(@hasDecl(v, "nonNegative"));
    try testing.expect(@TypeOf(v.nonNegative) == v.Rule);
    try testing.expectEqualStrings("validation.non_negative", v.nonNegative.code);
    try testing.expectEqualStrings("must not be negative", v.nonNegative.message);
}

test "negative is a rule value with code validation.negative and message \"must be less than 0\"" {
    try testing.expect(@hasDecl(v, "negative"));
    try testing.expect(@TypeOf(v.negative) == v.Rule);
    try testing.expectEqualStrings("validation.negative", v.negative.code);
    try testing.expectEqualStrings("must be less than 0", v.negative.message);
}

test "nonPositive is a rule value with code validation.non_positive and message \"must not be positive\"" {
    try testing.expect(@hasDecl(v, "nonPositive"));
    try testing.expect(@TypeOf(v.nonPositive) == v.Rule);
    try testing.expectEqualStrings("validation.non_positive", v.nonPositive.code);
    try testing.expectEqualStrings("must not be positive", v.nonPositive.message);
}

test "divisibleBy is a rule constructor with code validation.divisible_by and message \"must be divisible by {divisor}\"" {
    try testing.expect(@hasDecl(v, "divisibleBy"));
    try testing.expect(@typeInfo(@TypeOf(v.divisibleBy)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.divisible_by", v.divisibleBy(5).code);
    try testing.expectEqualStrings("must be divisible by 5", v.divisibleBy(5).message);
    try expectViolation(u32, v.divisibleBy(5), 7, "validation.divisible_by", "must be divisible by 5", "x");
    try expectNoViolation(u32, v.divisibleBy(5), 10);
}

test "finite is a rule value with code validation.finite and message \"must be a finite number\"" {
    try testing.expect(@hasDecl(v, "finite"));
    try testing.expect(@TypeOf(v.finite) == v.Rule);
    try testing.expectEqualStrings("validation.finite", v.finite.code);
    try testing.expectEqualStrings("must be a finite number", v.finite.message);
}

test "minItems is a rule constructor with code validation.min_items and message \"must have at least {min} items\", or \"must have at least 1 item\" when min = 1" {
    try testing.expect(@hasDecl(v, "minItems"));
    try testing.expect(@typeInfo(@TypeOf(v.minItems)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.min_items", v.minItems(2).code);
    try testing.expectEqualStrings("must have at least 2 items", v.minItems(2).message);
    try testing.expectEqualStrings("validation.min_items", v.minItems(1).code);
    try testing.expectEqualStrings("must have at least 1 item", v.minItems(1).message);
    try expectViolation([]const u32, v.minItems(2), &.{1}, "validation.min_items", "must have at least 2 items", "x");
    try expectViolation([]const u32, v.minItems(1), &.{}, "validation.min_items", "must have at least 1 item", "x");
    try expectNoViolation([]const u32, v.minItems(2), &.{ 1, 2 });
    // No precondition: items are counted, never checked.
    try expectNoViolation([]const f64, v.minItems(1), &.{std.math.nan(f64)});
}

test "maxItems is a rule constructor with code validation.max_items and message \"must have at most {max} items\", or \"must have at most 1 item\" when max = 1" {
    try testing.expect(@hasDecl(v, "maxItems"));
    try testing.expect(@typeInfo(@TypeOf(v.maxItems)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("validation.max_items", v.maxItems(100).code);
    try testing.expectEqualStrings("must have at most 100 items", v.maxItems(100).message);
    try testing.expectEqualStrings("validation.max_items", v.maxItems(1).code);
    try testing.expectEqualStrings("must have at most 1 item", v.maxItems(1).message);
    try expectViolation([]const u32, v.maxItems(2), &.{ 1, 2, 3 }, "validation.max_items", "must have at most 2 items", "x");
    try expectViolation([]const u32, v.maxItems(1), &.{ 1, 2 }, "validation.max_items", "must have at most 1 item", "x");
    try expectNoViolation([]const u32, v.maxItems(2), &.{ 1, 2 });
    // No precondition: items are counted, never checked.
    try expectNoViolation([]const f64, v.maxItems(1), &.{std.math.nan(f64)});
}

test "each is a rule constructor with no code or message of its own; an item reports the inner rule's code and message at its index" {
    try testing.expect(@hasDecl(v, "each"));
    try testing.expect(@typeInfo(@TypeOf(v.each)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("", v.each(v.notEmpty).code);
    try testing.expectEqualStrings("", v.each(v.notEmpty).message);
    try expectViolation([]const []const u8, v.each(v.notEmpty), &.{ "a", "" }, "validation.not_empty", "must not be empty", "x[1]");
    try expectViolation([]const u32, v.each(.{ v.positive, v.custom("acme.even", "must be even", isEven) }), &.{ 2, 3 }, "acme.even", "must be even", "x[1]");
    try expectNoViolation([]const []const u8, v.each(v.notEmpty), &.{ "a", "b" });
}

test "custom is a rule constructor whose code and literal message are its arguments" {
    try testing.expect(@hasDecl(v, "custom"));
    try testing.expect(@typeInfo(@TypeOf(v.custom)).@"fn".return_type == v.Rule);
    const literal = v.custom("acme.even", "must be even, not {odd} }}", isEven);
    try testing.expectEqualStrings("acme.even", literal.code);
    try testing.expectEqualStrings("must be even, not {odd} }}", literal.message);
    try expectViolation(u32, v.custom("acme.even", "must be even", isEven), 3, "acme.even", "must be even", "x");
    try expectNoViolation(u32, v.custom("acme.even", "must be even", isEven), 4);
}

test "positive on a float field fails nan, inf and -inf with the finite precondition" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.positive, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "min, max, range, nonNegative, negative, nonPositive and divisibleBy on a float field fail nan, inf and -inf with the finite precondition" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        inline for (.{ std.math.nan(F), std.math.inf(F), -std.math.inf(F) }) |bad| {
            try expectViolation(F, v.min(0), bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.max(0), bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.range(0, 1), bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.nonNegative, bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.negative, bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.nonPositive, bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.divisibleBy(2), bad, "validation.finite", "must be a finite number", "x");
        }
    }
}

test "equals and notEquals on a float field fail nan, inf and -inf with the finite precondition" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        inline for (.{ std.math.nan(F), std.math.inf(F), -std.math.inf(F) }) |bad| {
            try expectViolation(F, v.equals(0), bad, "validation.finite", "must be a finite number", "x");
            try expectViolation(F, v.notEquals(0), bad, "validation.finite", "must be a finite number", "x");
        }
    }
}

test "finite has no precondition: nan, inf and -inf fail its own check" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        inline for (.{ std.math.nan(F), std.math.inf(F), -std.math.inf(F) }) |bad| {
            try expectViolation(F, v.finite, bad, "validation.finite", "must be a finite number", "x");
        }
        try expectNoViolation(F, v.finite, std.math.floatMax(F));
    }
}

test "every rule the module exports has a catalog test" {
    const tested = [_][]const u8{ "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty", "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite", "minItems", "maxItems", "each", "custom" };
    inline for (comptime std.meta.declarations(v)) |name| {
        const T = @TypeOf(@field(v, name));
        if (comptime T == v.Rule or (@typeInfo(T) == .@"fn" and @typeInfo(T).@"fn".return_type == v.Rule)) {
            const listed = comptime for (tested) |rule| {
                if (std.mem.eql(u8, rule, name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("v.{s} is a rule without a catalog test: add its test to catalog_test.zig and its name to `tested`\n", .{name});
                return error.TestUntestedRule;
            }
        }
    }
}

test "the module exports exactly the catalog predicates of the shipped rules" {
    const predicates = [_][]const u8{};
    comptime var exported: usize = 0;
    inline for (comptime std.meta.declarations(v)) |name| {
        if (comptime name.len > 2 and std.mem.startsWith(u8, name, "is") and std.ascii.isUpper(name[2])) {
            exported += 1;
            const listed = comptime for (predicates) |predicate| {
                if (std.mem.eql(u8, predicate, name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("v.{s} is not a catalog predicate of a shipped rule\n", .{name});
                return error.TestUnexpectedPredicate;
            }
        }
    }
    try testing.expectEqual(predicates.len, exported);
}

test "the limits have their catalog values" {
    try testing.expect(@TypeOf(v.max_code_bytes) == comptime_int);
    try testing.expectEqual(128, v.max_code_bytes);
    try testing.expect(@TypeOf(v.max_message_bytes) == comptime_int);
    try testing.expectEqual(512, v.max_message_bytes);
    try testing.expect(@TypeOf(v.max_report_violations) == comptime_int);
    try testing.expectEqual(100, v.max_report_violations);
}
