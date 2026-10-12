//! Catalog conformance of the shipped rules: each rule is exported under its
//! catalog name in its catalog form (a rule value or a constructor) with the
//! catalog code and every variant of its catalog default message, which is
//! also what the catalog's text of the message gives through `withMessage`;
//! each placeholder shows its parameter through `withMessage`; a rule with a
//! precondition reports the catalog precondition code and message on every
//! field type it applies to, also under `withMessage`; the module exports
//! exactly its public names and the catalog predicates of the shipped rules,
//! and every rule it exports has a test here; and the limits have their
//! catalog values.
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

/// `rule` has this code and default message, and the catalog's `template` of
/// the message gives the same text through `withMessage`: the default message
/// is the template with the rule's placeholders filled in.
fn expectRule(comptime rule: v.Rule, code: []const u8, message: []const u8, comptime template: []const u8) !void {
    try testing.expectEqualStrings(code, rule.code);
    try testing.expectEqualStrings(message, rule.message);
    try testing.expectEqualStrings(message, rule.withMessage(template).message);
}

/// The placeholder `{name}` of `rule` shows `text` through `withMessage`.
fn expectPlaceholder(comptime rule: v.Rule, comptime placeholder: []const u8, text: []const u8) !void {
    try testing.expectEqualStrings(text, rule.withMessage(placeholder).message);
}

/// A string parameter whose default message would be longer than 512 bytes.
const long_string = &@as([600]u8, @splat('x'));

/// Listed values whose default message would be longer than 512 bytes.
const long_values = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

test "equals is a rule constructor with code validation.equals and message \"must be equal to {expected}\", or \"must be equal to the expected value\" when that would be longer than 512 bytes; placeholder {expected}" {
    try testing.expect(@hasDecl(v, "equals"));
    try testing.expect(@typeInfo(@TypeOf(v.equals)).@"fn".return_type == v.Rule);
    try expectRule(v.equals(true), "validation.equals", "must be equal to true", "must be equal to {expected}");
    try expectPlaceholder(v.equals(true), "{expected}", "true");
    try expectViolation(bool, v.equals(true), false, "validation.equals", "must be equal to true", "x");
    try expectRule(v.equals(long_string), "validation.equals", "must be equal to the expected value", "must be equal to the expected value");
    try expectViolation([]const u8, v.equals(long_string), "x", "validation.equals", "must be equal to the expected value", "x");
    try expectNoViolation(bool, v.equals(true), true);
}

test "notEquals is a rule constructor with code validation.not_equals and message \"must not be equal to {forbidden}\", or \"must not be equal to the forbidden value\" when that would be longer than 512 bytes; placeholder {forbidden}" {
    try testing.expect(@hasDecl(v, "notEquals"));
    try testing.expect(@typeInfo(@TypeOf(v.notEquals)).@"fn".return_type == v.Rule);
    try expectRule(v.notEquals(0), "validation.not_equals", "must not be equal to 0", "must not be equal to {forbidden}");
    try expectPlaceholder(v.notEquals(0), "{forbidden}", "0");
    try expectViolation(i32, v.notEquals(0), 0, "validation.not_equals", "must not be equal to 0", "x");
    try expectRule(v.notEquals(long_string), "validation.not_equals", "must not be equal to the forbidden value", "must not be equal to the forbidden value");
    try expectViolation([]const u8, v.notEquals(long_string), long_string, "validation.not_equals", "must not be equal to the forbidden value", "x");
    try expectNoViolation(i32, v.notEquals(0), 1);
}

test "oneOf is a rule constructor with code validation.one_of and message \"must be one of: {values}\", \"must be {values}\" for one value, or \"must be one of the allowed values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "oneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.oneOf)).@"fn".return_type == v.Rule);
    try expectRule(v.oneOf(.{ "a", "b" }), "validation.one_of", "must be one of: a, b", "must be one of: {values}");
    try expectPlaceholder(v.oneOf(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const u8, v.oneOf(.{ "a", "b" }), "c", "validation.one_of", "must be one of: a, b", "x");
    try expectRule(v.oneOf(.{"a"}), "validation.one_of", "must be a", "must be {values}");
    try expectPlaceholder(v.oneOf(.{"a"}), "{values}", "a");
    try expectViolation([]const u8, v.oneOf(.{"a"}), "c", "validation.one_of", "must be a", "x");
    try expectRule(v.oneOf(long_values), "validation.one_of", "must be one of the allowed values", "must be one of the allowed values");
    try expectViolation([]const u8, v.oneOf(long_values), "c", "validation.one_of", "must be one of the allowed values", "x");
    try expectNoViolation([]const u8, v.oneOf(.{ "a", "b" }), "b");
}

test "noneOf is a rule constructor with code validation.none_of and message \"must not be one of: {values}\", \"must not be {values}\" for one value, or \"must not be one of the forbidden values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "noneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.noneOf)).@"fn".return_type == v.Rule);
    try expectRule(v.noneOf(.{ "a", "b" }), "validation.none_of", "must not be one of: a, b", "must not be one of: {values}");
    try expectPlaceholder(v.noneOf(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const u8, v.noneOf(.{ "a", "b" }), "b", "validation.none_of", "must not be one of: a, b", "x");
    try expectRule(v.noneOf(.{"a"}), "validation.none_of", "must not be a", "must not be {values}");
    try expectPlaceholder(v.noneOf(.{"a"}), "{values}", "a");
    try expectViolation([]const u8, v.noneOf(.{"a"}), "a", "validation.none_of", "must not be a", "x");
    try expectRule(v.noneOf(long_values), "validation.none_of", "must not be one of the forbidden values", "must not be one of the forbidden values");
    try expectViolation([]const u8, v.noneOf(long_values), long_values[0], "validation.none_of", "must not be one of the forbidden values", "x");
    try expectNoViolation([]const u8, v.noneOf(.{ "a", "b" }), "c");
}

test "empty is a rule value with code validation.empty and message \"must be empty\"" {
    try testing.expect(@hasDecl(v, "empty"));
    try testing.expect(@TypeOf(v.empty) == v.Rule);
    try expectRule(v.empty, "validation.empty", "must be empty", "must be empty");
    try expectViolation([]const u8, v.empty, "a", "validation.empty", "must be empty", "x");
    try expectNoViolation([]const u8, v.empty, "");
}

test "notEmpty is a rule value with code validation.not_empty and message \"must not be empty\"" {
    try testing.expect(@hasDecl(v, "notEmpty"));
    try testing.expect(@TypeOf(v.notEmpty) == v.Rule);
    try expectRule(v.notEmpty, "validation.not_empty", "must not be empty", "must not be empty");
    try expectViolation([]const u8, v.notEmpty, "", "validation.not_empty", "must not be empty", "x");
    try expectNoViolation([]const u8, v.notEmpty, "a");
}

test "min is a rule constructor with code validation.min and message \"must be at least {min}\"; placeholder {min}" {
    try testing.expect(@hasDecl(v, "min"));
    try testing.expect(@typeInfo(@TypeOf(v.min)).@"fn".return_type == v.Rule);
    try expectRule(v.min(0), "validation.min", "must be at least 0", "must be at least {min}");
    try expectPlaceholder(v.min(0), "{min}", "0");
    try expectViolation(i32, v.min(0), -1, "validation.min", "must be at least 0", "x");
    try expectNoViolation(i32, v.min(0), 0);
}

test "max is a rule constructor with code validation.max and message \"must be at most {max}\"; placeholder {max}" {
    try testing.expect(@hasDecl(v, "max"));
    try testing.expect(@typeInfo(@TypeOf(v.max)).@"fn".return_type == v.Rule);
    try expectRule(v.max(100), "validation.max", "must be at most 100", "must be at most {max}");
    try expectPlaceholder(v.max(100), "{max}", "100");
    try expectViolation(i32, v.max(100), 101, "validation.max", "must be at most 100", "x");
    try expectNoViolation(i32, v.max(100), 100);
}

test "range is a rule constructor with code validation.range and message \"must be from {min} to {max}\", or \"must be {min}\" when min = max; placeholders {min}, {max}" {
    try testing.expect(@hasDecl(v, "range"));
    try testing.expect(@typeInfo(@TypeOf(v.range)).@"fn".return_type == v.Rule);
    try expectRule(v.range(1, 100), "validation.range", "must be from 1 to 100", "must be from {min} to {max}");
    try expectPlaceholder(v.range(1, 100), "{min}", "1");
    try expectPlaceholder(v.range(1, 100), "{max}", "100");
    try expectViolation(i32, v.range(1, 100), 0, "validation.range", "must be from 1 to 100", "x");
    try expectRule(v.range(1, 1), "validation.range", "must be 1", "must be {min}");
    try expectPlaceholder(v.range(1, 1), "{min}", "1");
    try expectViolation(i32, v.range(1, 1), 2, "validation.range", "must be 1", "x");
    try expectNoViolation(i32, v.range(1, 100), 1);
}

test "positive is a rule value with code validation.positive and message \"must be greater than 0\"" {
    try testing.expect(@hasDecl(v, "positive"));
    try testing.expect(@TypeOf(v.positive) == v.Rule);
    try expectRule(v.positive, "validation.positive", "must be greater than 0", "must be greater than 0");
    try expectViolation(i32, v.positive, 0, "validation.positive", "must be greater than 0", "x");
    try expectNoViolation(i32, v.positive, 1);
}

test "nonNegative is a rule value with code validation.non_negative and message \"must not be negative\"" {
    try testing.expect(@hasDecl(v, "nonNegative"));
    try testing.expect(@TypeOf(v.nonNegative) == v.Rule);
    try expectRule(v.nonNegative, "validation.non_negative", "must not be negative", "must not be negative");
    try expectViolation(i32, v.nonNegative, -1, "validation.non_negative", "must not be negative", "x");
    try expectNoViolation(i32, v.nonNegative, 0);
}

test "negative is a rule value with code validation.negative and message \"must be less than 0\"" {
    try testing.expect(@hasDecl(v, "negative"));
    try testing.expect(@TypeOf(v.negative) == v.Rule);
    try expectRule(v.negative, "validation.negative", "must be less than 0", "must be less than 0");
    try expectViolation(i32, v.negative, 0, "validation.negative", "must be less than 0", "x");
    try expectNoViolation(i32, v.negative, -1);
}

test "nonPositive is a rule value with code validation.non_positive and message \"must not be positive\"" {
    try testing.expect(@hasDecl(v, "nonPositive"));
    try testing.expect(@TypeOf(v.nonPositive) == v.Rule);
    try expectRule(v.nonPositive, "validation.non_positive", "must not be positive", "must not be positive");
    try expectViolation(i32, v.nonPositive, 1, "validation.non_positive", "must not be positive", "x");
    try expectNoViolation(i32, v.nonPositive, 0);
}

test "divisibleBy is a rule constructor with code validation.divisible_by and message \"must be divisible by {divisor}\"; placeholder {divisor}" {
    try testing.expect(@hasDecl(v, "divisibleBy"));
    try testing.expect(@typeInfo(@TypeOf(v.divisibleBy)).@"fn".return_type == v.Rule);
    try expectRule(v.divisibleBy(2), "validation.divisible_by", "must be divisible by 2", "must be divisible by {divisor}");
    try expectPlaceholder(v.divisibleBy(2), "{divisor}", "2");
    try expectViolation(i32, v.divisibleBy(2), 3, "validation.divisible_by", "must be divisible by 2", "x");
    try expectNoViolation(i32, v.divisibleBy(2), 4);
}

test "finite is a rule value with code validation.finite and message \"must be a finite number\"" {
    try testing.expect(@hasDecl(v, "finite"));
    try testing.expect(@TypeOf(v.finite) == v.Rule);
    try expectRule(v.finite, "validation.finite", "must be a finite number", "must be a finite number");
    try expectViolation(f64, v.finite, std.math.inf(f64), "validation.finite", "must be a finite number", "x");
    try expectNoViolation(f64, v.finite, 0);
}

test "minLength is a rule constructor with code validation.min_length and message \"must be at least {min} characters\", or \"must be at least 1 character\" when min = 1; placeholder {min}" {
    try testing.expect(@hasDecl(v, "minLength"));
    try testing.expect(@typeInfo(@TypeOf(v.minLength)).@"fn".return_type == v.Rule);
    try expectRule(v.minLength(3), "validation.min_length", "must be at least 3 characters", "must be at least {min} characters");
    try expectPlaceholder(v.minLength(3), "{min}", "3");
    try expectViolation([]const u8, v.minLength(3), "ab", "validation.min_length", "must be at least 3 characters", "x");
    try expectRule(v.minLength(1), "validation.min_length", "must be at least 1 character", "must be at least 1 character");
    try expectViolation([]const u8, v.minLength(1), "", "validation.min_length", "must be at least 1 character", "x");
    try expectNoViolation([]const u8, v.minLength(3), "abc");
}

test "maxLength is a rule constructor with code validation.max_length and message \"must be at most {max} characters\", or \"must be at most 1 character\" when max = 1; placeholder {max}" {
    try testing.expect(@hasDecl(v, "maxLength"));
    try testing.expect(@typeInfo(@TypeOf(v.maxLength)).@"fn".return_type == v.Rule);
    try expectRule(v.maxLength(64), "validation.max_length", "must be at most 64 characters", "must be at most {max} characters");
    try expectPlaceholder(v.maxLength(64), "{max}", "64");
    try expectViolation([]const u8, v.maxLength(2), "abc", "validation.max_length", "must be at most 2 characters", "x");
    try expectRule(v.maxLength(1), "validation.max_length", "must be at most 1 character", "must be at most 1 character");
    try expectViolation([]const u8, v.maxLength(1), "ab", "validation.max_length", "must be at most 1 character", "x");
    try expectNoViolation([]const u8, v.maxLength(2), "");
}

test "length is a rule constructor with code validation.length and message \"must be from {min} to {max} characters\", \"must be exactly {min} characters\" when min = max, or \"must be exactly 1 character\" when min = max = 1; placeholders {min}, {max}" {
    try testing.expect(@hasDecl(v, "length"));
    try testing.expect(@typeInfo(@TypeOf(v.length)).@"fn".return_type == v.Rule);
    try expectRule(v.length(3, 32), "validation.length", "must be from 3 to 32 characters", "must be from {min} to {max} characters");
    try expectPlaceholder(v.length(3, 32), "{min}", "3");
    try expectPlaceholder(v.length(3, 32), "{max}", "32");
    try expectViolation([]const u8, v.length(3, 32), "ab", "validation.length", "must be from 3 to 32 characters", "x");
    try expectRule(v.length(5, 5), "validation.length", "must be exactly 5 characters", "must be exactly {min} characters");
    try expectPlaceholder(v.length(5, 5), "{max}", "5");
    try expectViolation([]const u8, v.length(5, 5), "abcd", "validation.length", "must be exactly 5 characters", "x");
    try expectRule(v.length(1, 1), "validation.length", "must be exactly 1 character", "must be exactly 1 character");
    try expectViolation([]const u8, v.length(1, 1), "ab", "validation.length", "must be exactly 1 character", "x");
    try expectNoViolation([]const u8, v.length(3, 32), "abc");
}

test "minBytes is a rule constructor with code validation.min_bytes and message \"must be at least {min} bytes\", or \"must be at least 1 byte\" when min = 1; placeholder {min}" {
    try testing.expect(@hasDecl(v, "minBytes"));
    try testing.expect(@typeInfo(@TypeOf(v.minBytes)).@"fn".return_type == v.Rule);
    try expectRule(v.minBytes(8), "validation.min_bytes", "must be at least 8 bytes", "must be at least {min} bytes");
    try expectPlaceholder(v.minBytes(8), "{min}", "8");
    try expectViolation([]const u8, v.minBytes(8), "abc", "validation.min_bytes", "must be at least 8 bytes", "x");
    try expectRule(v.minBytes(1), "validation.min_bytes", "must be at least 1 byte", "must be at least 1 byte");
    try expectViolation([]const u8, v.minBytes(1), "", "validation.min_bytes", "must be at least 1 byte", "x");
    try expectNoViolation([]const u8, v.minBytes(2), "\xff\xff");
}

test "maxBytes is a rule constructor with code validation.max_bytes and message \"must be at most {max} bytes\", or \"must be at most 1 byte\" when max = 1; placeholder {max}" {
    try testing.expect(@hasDecl(v, "maxBytes"));
    try testing.expect(@typeInfo(@TypeOf(v.maxBytes)).@"fn".return_type == v.Rule);
    try expectRule(v.maxBytes(255), "validation.max_bytes", "must be at most 255 bytes", "must be at most {max} bytes");
    try expectPlaceholder(v.maxBytes(255), "{max}", "255");
    try expectViolation([]const u8, v.maxBytes(2), "abc", "validation.max_bytes", "must be at most 2 bytes", "x");
    try expectRule(v.maxBytes(1), "validation.max_bytes", "must be at most 1 byte", "must be at most 1 byte");
    try expectViolation([]const u8, v.maxBytes(1), "\u{E9}", "validation.max_bytes", "must be at most 1 byte", "x");
    try expectNoViolation([]const u8, v.maxBytes(3), "\xff\xff\xff");
}

test "utf8 is a rule value with code validation.utf8 and message \"must be valid UTF-8\"" {
    try testing.expect(@hasDecl(v, "utf8"));
    try testing.expect(@TypeOf(v.utf8) == v.Rule);
    try expectRule(v.utf8, "validation.utf8", "must be valid UTF-8", "must be valid UTF-8");
    try expectViolation([]const u8, v.utf8, "\xff", "validation.utf8", "must be valid UTF-8", "x");
    try expectNoViolation([]const u8, v.utf8, "");
}

test "notBlank is a rule value with code validation.not_blank and message \"must not be blank\"" {
    try testing.expect(@hasDecl(v, "notBlank"));
    try testing.expect(@TypeOf(v.notBlank) == v.Rule);
    try expectRule(v.notBlank, "validation.not_blank", "must not be blank", "must not be blank");
    try expectViolation([]const u8, v.notBlank, " \u{3000}", "validation.not_blank", "must not be blank", "x");
    try expectNoViolation([]const u8, v.notBlank, " a ");
}

test "ascii is a rule value with code validation.ascii and message \"must contain only ASCII characters\"" {
    try testing.expect(@hasDecl(v, "ascii"));
    try testing.expect(@TypeOf(v.ascii) == v.Rule);
    try expectRule(v.ascii, "validation.ascii", "must contain only ASCII characters", "must contain only ASCII characters");
    try expectViolation([]const u8, v.ascii, "caf\u{E9}", "validation.ascii", "must contain only ASCII characters", "x");
    try expectNoViolation([]const u8, v.ascii, "");
}

test "printableAscii is a rule value with code validation.printable_ascii and message \"must contain only printable ASCII characters\"" {
    try testing.expect(@hasDecl(v, "printableAscii"));
    try testing.expect(@TypeOf(v.printableAscii) == v.Rule);
    try expectRule(v.printableAscii, "validation.printable_ascii", "must contain only printable ASCII characters", "must contain only printable ASCII characters");
    try expectViolation([]const u8, v.printableAscii, "a\tb", "validation.printable_ascii", "must contain only printable ASCII characters", "x");
    try expectNoViolation([]const u8, v.printableAscii, "a b");
}

test "alphanumeric is a rule value with code validation.alphanumeric and message \"must contain only ASCII letters and digits\"" {
    try testing.expect(@hasDecl(v, "alphanumeric"));
    try testing.expect(@TypeOf(v.alphanumeric) == v.Rule);
    try expectRule(v.alphanumeric, "validation.alphanumeric", "must contain only ASCII letters and digits", "must contain only ASCII letters and digits");
    try expectViolation([]const u8, v.alphanumeric, "a_1", "validation.alphanumeric", "must contain only ASCII letters and digits", "x");
    try expectNoViolation([]const u8, v.alphanumeric, "a1");
}

test "alpha is a rule value with code validation.alpha and message \"must contain only ASCII letters\"" {
    try testing.expect(@hasDecl(v, "alpha"));
    try testing.expect(@TypeOf(v.alpha) == v.Rule);
    try expectRule(v.alpha, "validation.alpha", "must contain only ASCII letters", "must contain only ASCII letters");
    try expectViolation([]const u8, v.alpha, "a1", "validation.alpha", "must contain only ASCII letters", "x");
    try expectNoViolation([]const u8, v.alpha, "Ab");
}

test "digits is a rule value with code validation.digits and message \"must contain only ASCII digits\"" {
    try testing.expect(@hasDecl(v, "digits"));
    try testing.expect(@TypeOf(v.digits) == v.Rule);
    try expectRule(v.digits, "validation.digits", "must contain only ASCII digits", "must contain only ASCII digits");
    try expectViolation([]const u8, v.digits, "-1", "validation.digits", "must contain only ASCII digits", "x");
    try expectNoViolation([]const u8, v.digits, "0123");
}

test "lowercase is a rule value with code validation.lowercase and message \"must be lowercase\"" {
    try testing.expect(@hasDecl(v, "lowercase"));
    try testing.expect(@TypeOf(v.lowercase) == v.Rule);
    try expectRule(v.lowercase, "validation.lowercase", "must be lowercase", "must be lowercase");
    try expectViolation([]const u8, v.lowercase, "aB", "validation.lowercase", "must be lowercase", "x");
    try expectNoViolation([]const u8, v.lowercase, "ab-1");
}

test "uppercase is a rule value with code validation.uppercase and message \"must be uppercase\"" {
    try testing.expect(@hasDecl(v, "uppercase"));
    try testing.expect(@TypeOf(v.uppercase) == v.Rule);
    try expectRule(v.uppercase, "validation.uppercase", "must be uppercase", "must be uppercase");
    try expectViolation([]const u8, v.uppercase, "Ab", "validation.uppercase", "must be uppercase", "x");
    try expectNoViolation([]const u8, v.uppercase, "AB-1");
}

test "multibyte is a rule value with code validation.multibyte and message \"must contain at least one non-ASCII character\"" {
    try testing.expect(@hasDecl(v, "multibyte"));
    try testing.expect(@TypeOf(v.multibyte) == v.Rule);
    try expectRule(v.multibyte, "validation.multibyte", "must contain at least one non-ASCII character", "must contain at least one non-ASCII character");
    try expectViolation([]const u8, v.multibyte, "abc", "validation.multibyte", "must contain at least one non-ASCII character", "x");
    try expectNoViolation([]const u8, v.multibyte, "caf\u{E9}");
}

test "fullWidth is a rule value with code validation.full_width and message \"must contain at least one full-width character\"" {
    try testing.expect(@hasDecl(v, "fullWidth"));
    try testing.expect(@TypeOf(v.fullWidth) == v.Rule);
    try expectRule(v.fullWidth, "validation.full_width", "must contain at least one full-width character", "must contain at least one full-width character");
    try expectViolation([]const u8, v.fullWidth, "\u{FF71}", "validation.full_width", "must contain at least one full-width character", "x");
    try expectNoViolation([]const u8, v.fullWidth, "\u{3042}");
}

test "halfWidth is a rule value with code validation.half_width and message \"must contain at least one half-width character\"" {
    try testing.expect(@hasDecl(v, "halfWidth"));
    try testing.expect(@TypeOf(v.halfWidth) == v.Rule);
    try expectRule(v.halfWidth, "validation.half_width", "must contain at least one half-width character", "must contain at least one half-width character");
    try expectViolation([]const u8, v.halfWidth, "\u{3042}", "validation.half_width", "must contain at least one half-width character", "x");
    try expectNoViolation([]const u8, v.halfWidth, "\u{FF71}");
}

test "variableWidth is a rule value with code validation.variable_width and message \"must contain both full-width and half-width characters\"" {
    try testing.expect(@hasDecl(v, "variableWidth"));
    try testing.expect(@TypeOf(v.variableWidth) == v.Rule);
    try expectRule(v.variableWidth, "validation.variable_width", "must contain both full-width and half-width characters", "must contain both full-width and half-width characters");
    try expectViolation([]const u8, v.variableWidth, "\u{3042}", "validation.variable_width", "must contain both full-width and half-width characters", "x");
    try expectNoViolation([]const u8, v.variableWidth, "\u{3042}a");
}

/// `rules` fail an invalid UTF-8 value with the utf8 precondition on every
/// kind of string field.
fn expectUtf8Precondition(comptime rules: anytype) !void {
    const code = "validation.utf8";
    const message = "must be valid UTF-8";
    try expectViolation([]const u8, rules, "a\xff", code, message, "x");
    try expectViolation([:0]const u8, rules, "a\xff", code, message, "x");
    var bytes = "a\xff".*;
    try expectViolation([]u8, rules, &bytes, code, message, "x");
    try expectViolation([:0]u8, rules, bytes[0..2 :0], code, message, "x");
    try expectViolation(?[]const u8, rules, "\xed\xa0\x80", code, message, "x");
}

test "minLength on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.minLength(1));
    try expectUtf8Precondition(v.minLength(1).withMessage("another message"));
}

test "maxLength on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.maxLength(10));
    try expectUtf8Precondition(v.maxLength(10).withMessage("another message"));
}

test "length on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.length(1, 10));
    try expectUtf8Precondition(v.length(1, 10).withMessage("another message"));
}

test "notBlank on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.notBlank);
    try expectUtf8Precondition(v.notBlank.withMessage("another message"));
}

test "fullWidth on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.fullWidth);
    try expectUtf8Precondition(v.fullWidth.withMessage("another message"));
}

test "halfWidth on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.halfWidth);
    try expectUtf8Precondition(v.halfWidth.withMessage("another message"));
}

test "variableWidth on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.variableWidth);
    try expectUtf8Precondition(v.variableWidth.withMessage("another message"));
}

test "utf8 has no precondition: invalid UTF-8 fails its own check, so withMessage changes its message" {
    try expectViolation([]const u8, v.utf8, "a\xff", "validation.utf8", "must be valid UTF-8", "x");
    try expectViolation([]const u8, v.utf8.withMessage("another message"), "a\xff", "validation.utf8", "another message", "x");
    try expectNoViolation([]const u8, v.utf8, "\u{10FFFF}");
}

test "minItems is a rule constructor with code validation.min_items and message \"must have at least {min} items\", or \"must have at least 1 item\" when min = 1; placeholder {min}" {
    try testing.expect(@hasDecl(v, "minItems"));
    try testing.expect(@typeInfo(@TypeOf(v.minItems)).@"fn".return_type == v.Rule);
    try expectRule(v.minItems(2), "validation.min_items", "must have at least 2 items", "must have at least {min} items");
    try expectPlaceholder(v.minItems(2), "{min}", "2");
    try expectViolation([]const u32, v.minItems(2), &.{1}, "validation.min_items", "must have at least 2 items", "x");
    try expectRule(v.minItems(1), "validation.min_items", "must have at least 1 item", "must have at least 1 item");
    try expectViolation([]const u32, v.minItems(1), &.{}, "validation.min_items", "must have at least 1 item", "x");
    try expectNoViolation([]const u32, v.minItems(2), &.{ 1, 2 });
}

test "maxItems is a rule constructor with code validation.max_items and message \"must have at most {max} items\", or \"must have at most 1 item\" when max = 1; placeholder {max}" {
    try testing.expect(@hasDecl(v, "maxItems"));
    try testing.expect(@typeInfo(@TypeOf(v.maxItems)).@"fn".return_type == v.Rule);
    try expectRule(v.maxItems(2), "validation.max_items", "must have at most 2 items", "must have at most {max} items");
    try expectPlaceholder(v.maxItems(2), "{max}", "2");
    try expectViolation([]const u32, v.maxItems(2), &.{ 1, 2, 3 }, "validation.max_items", "must have at most 2 items", "x");
    try expectRule(v.maxItems(1), "validation.max_items", "must have at most 1 item", "must have at most 1 item");
    try expectViolation([]const u32, v.maxItems(1), &.{ 1, 2 }, "validation.max_items", "must have at most 1 item", "x");
    try expectNoViolation([]const u32, v.maxItems(2), &.{1});
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

test "equals on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.equals(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "notEquals on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.notEquals(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "min on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.min(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "max on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.max(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "range on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.range(0, 1), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "positive on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.positive, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "nonNegative on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.nonNegative, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "negative on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.negative, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "nonPositive on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.nonPositive, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "divisibleBy on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.divisibleBy(2), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "finite has no precondition: nan, inf and -inf on a float field fail its own check, so withMessage changes their message" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.finite, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), std.math.nan(F), "validation.finite", "another message", "x");
        try expectViolation(F, v.finite, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), std.math.inf(F), "validation.finite", "another message", "x");
        try expectViolation(F, v.finite, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), -std.math.inf(F), "validation.finite", "another message", "x");
        try expectNoViolation(F, v.finite, std.math.floatMax(F));
    }
}

test "the module exports exactly its 60 public names, and Rule.withMessage" {
    const names = [_][]const u8{ "Violation", "Rule", "Report", "max_code_bytes", "max_message_bytes", "max_report_violations", "check", "checkAll", "assertRules", "fail", "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty", "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite", "minLength", "maxLength", "length", "minBytes", "maxBytes", "utf8", "notBlank", "ascii", "printableAscii", "alphanumeric", "alpha", "digits", "lowercase", "uppercase", "multibyte", "fullWidth", "halfWidth", "variableWidth", "isUtf8", "isNotBlank", "isAscii", "isPrintableAscii", "isAlphanumeric", "isAlpha", "isDigits", "isLowercase", "isUppercase", "isMultibyte", "isFullWidth", "isHalfWidth", "isVariableWidth", "minItems", "maxItems", "each", "custom" };
    inline for (names) |name| try testing.expect(@hasDecl(v, name));
    try testing.expectEqual(names.len, comptime std.meta.declarations(v).len);
    try testing.expect(@hasDecl(v.Rule, "withMessage"));
}

test "every rule the module exports has a catalog test" {
    @setEvalBranchQuota(100_000);
    const tested = [_][]const u8{ "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty", "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite", "minLength", "maxLength", "length", "minBytes", "maxBytes", "utf8", "notBlank", "ascii", "printableAscii", "alphanumeric", "alpha", "digits", "lowercase", "uppercase", "multibyte", "fullWidth", "halfWidth", "variableWidth", "minItems", "maxItems", "each", "custom" };
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
    @setEvalBranchQuota(100_000);
    const predicates = [_][]const u8{ "isUtf8", "isNotBlank", "isAscii", "isPrintableAscii", "isAlphanumeric", "isAlpha", "isDigits", "isLowercase", "isUppercase", "isMultibyte", "isFullWidth", "isHalfWidth", "isVariableWidth" };
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
