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

test "contains is a rule constructor with code validation.contains and message \"must contain \\\"{seed}\\\"\", or \"must contain the required text\" when that would be longer than 512 bytes; placeholder {seed}" {
    try testing.expect(@hasDecl(v, "contains"));
    try testing.expect(@typeInfo(@TypeOf(v.contains)).@"fn".return_type == v.Rule);
    try expectRule(v.contains("@"), "validation.contains", "must contain \"@\"", "must contain \"{seed}\"");
    try expectPlaceholder(v.contains("@"), "{seed}", "@");
    try expectViolation([]const u8, v.contains("@"), "ab", "validation.contains", "must contain \"@\"", "x");
    try expectRule(v.contains(long_string), "validation.contains", "must contain the required text", "must contain the required text");
    try expectViolation([]const u8, v.contains(long_string), "x", "validation.contains", "must contain the required text", "x");
    try expectNoViolation([]const u8, v.contains("@"), "a@b");
}

test "notContains is a rule constructor with code validation.not_contains and message \"must not contain \\\"{seed}\\\"\", or \"must not contain the forbidden text\" when that would be longer than 512 bytes; placeholder {seed}" {
    try testing.expect(@hasDecl(v, "notContains"));
    try testing.expect(@typeInfo(@TypeOf(v.notContains)).@"fn".return_type == v.Rule);
    try expectRule(v.notContains(" "), "validation.not_contains", "must not contain \" \"", "must not contain \"{seed}\"");
    try expectPlaceholder(v.notContains(" "), "{seed}", " ");
    try expectViolation([]const u8, v.notContains(" "), "a b", "validation.not_contains", "must not contain \" \"", "x");
    try expectRule(v.notContains(long_string), "validation.not_contains", "must not contain the forbidden text", "must not contain the forbidden text");
    try expectViolation([]const u8, v.notContains(long_string), long_string, "validation.not_contains", "must not contain the forbidden text", "x");
    try expectNoViolation([]const u8, v.notContains(" "), "");
}

test "strongPassword is a rule constructor with code validation.strong_password and message \"must be at least {min_length} characters and contain at least {min_lowercase} lowercase letters, {min_uppercase} uppercase letters, {min_numbers} digits and {min_symbols} symbols\", leaving out a minimum of 0, singular for 1; placeholders {min_length}, {min_lowercase}, {min_uppercase}, {min_numbers}, {min_symbols}" {
    try testing.expect(@hasDecl(v, "strongPassword"));
    try testing.expect(@typeInfo(@TypeOf(v.strongPassword)).@"fn".return_type == v.Rule);
    try testing.expect(@hasDecl(v, "StrongPasswordOptions"));
    const template = "must be at least {min_length} characters and contain at least {min_lowercase} lowercase letters, {min_uppercase} uppercase letters, {min_numbers} digits and {min_symbols} symbols";
    const two = v.strongPassword(.{ .min_length = 12, .min_lowercase = 2, .min_uppercase = 2, .min_numbers = 2, .min_symbols = 2 });
    try expectRule(two, "validation.strong_password", "must be at least 12 characters and contain at least 2 lowercase letters, 2 uppercase letters, 2 digits and 2 symbols", template);
    try expectPlaceholder(two, "{min_length}", "12");
    try expectPlaceholder(two, "{min_lowercase}", "2");
    try expectPlaceholder(two, "{min_uppercase}", "2");
    try expectPlaceholder(two, "{min_numbers}", "2");
    try expectPlaceholder(two, "{min_symbols}", "2");
    const defaults = "must be at least 8 characters and contain at least 1 lowercase letter, 1 uppercase letter, 1 digit and 1 symbol";
    try expectRule(v.strongPassword(.{}), "validation.strong_password", defaults, "must be at least {min_length} characters and contain at least {min_lowercase} lowercase letter, {min_uppercase} uppercase letter, {min_numbers} digit and {min_symbols} symbol");
    try expectViolation([]const u8, v.strongPassword(.{}), "abcdefgh", "validation.strong_password", defaults, "x");
    const length_only = v.strongPassword(.{ .min_length = 12, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 });
    try expectRule(length_only, "validation.strong_password", "must be at least 12 characters", "must be at least {min_length} characters");
    try expectPlaceholder(length_only, "{min_symbols}", "0");
    try expectRule(v.strongPassword(.{ .min_lowercase = 0, .min_uppercase = 0 }), "validation.strong_password", "must be at least 8 characters and contain at least 1 digit and 1 symbol", "must be at least {min_length} characters and contain at least {min_numbers} digit and {min_symbols} symbol");
    try expectNoViolation([]const u8, v.strongPassword(.{}), "Abcdef1!");
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

test "strongPassword on a string field fails invalid UTF-8 with the utf8 precondition, also under withMessage" {
    try expectUtf8Precondition(v.strongPassword(.{}));
    try expectUtf8Precondition(v.strongPassword(.{}).withMessage("another message"));
}

test "utf8 has no precondition: invalid UTF-8 fails its own check, so withMessage changes its message" {
    try expectViolation([]const u8, v.utf8, "a\xff", "validation.utf8", "must be valid UTF-8", "x");
    try expectViolation([]const u8, v.utf8.withMessage("another message"), "a\xff", "validation.utf8", "another message", "x");
    try expectNoViolation([]const u8, v.utf8, "\u{10FFFF}");
}

test "numberString is a rule value with code validation.number_string and message \"must be a number\"" {
    try testing.expect(@hasDecl(v, "numberString"));
    try testing.expect(@TypeOf(v.numberString) == v.Rule);
    try expectRule(v.numberString, "validation.number_string", "must be a number", "must be a number");
    try expectViolation([]const u8, v.numberString, "1e5", "validation.number_string", "must be a number", "x");
    try expectNoViolation([]const u8, v.numberString, "-12.5");
}

test "decimal is a rule constructor with code validation.decimal and message \"must be a decimal number\", or one of 7 messages for other options, \"decimal place\" for a count of 1; placeholders {min_decimal_digits} and, when set, {max_decimal_digits}" {
    try testing.expect(@hasDecl(v, "decimal"));
    try testing.expect(@typeInfo(@TypeOf(v.decimal)).@"fn".return_type == v.Rule);
    const code = "validation.decimal";
    try expectRule(v.decimal(.{}), code, "must be a decimal number", "must be a decimal number");
    try expectRule(v.decimal(.{ .min_decimal_digits = 2 }), code, "must be a whole number or have at least 2 decimal places", "must be a whole number or have at least {min_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .max_decimal_digits = 2 }), code, "must be a decimal number with at most 2 decimal places", "must be a decimal number with at most {max_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .max_decimal_digits = 1 }), code, "must be a decimal number with at most 1 decimal place", "must be a decimal number with at most {max_decimal_digits} decimal place");
    try expectRule(v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 2 }), code, "must be a whole number or have exactly 2 decimal places", "must be a whole number or have exactly {min_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 4 }), code, "must be a whole number or have 2 to 4 decimal places", "must be a whole number or have {min_decimal_digits} to {max_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .force_decimal = true, .min_decimal_digits = 2 }), code, "must be a decimal number with at least 2 decimal places", "must be a decimal number with at least {min_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .force_decimal = true }), code, "must be a decimal number with at least 1 decimal place", "must be a decimal number with at least {min_decimal_digits} decimal place");
    try expectRule(v.decimal(.{ .force_decimal = true, .min_decimal_digits = 2, .max_decimal_digits = 2 }), code, "must be a decimal number with exactly 2 decimal places", "must be a decimal number with exactly {min_decimal_digits} decimal places");
    try expectRule(v.decimal(.{ .force_decimal = true, .max_decimal_digits = 1 }), code, "must be a decimal number with exactly 1 decimal place", "must be a decimal number with exactly {min_decimal_digits} decimal place");
    try expectRule(v.decimal(.{ .force_decimal = true, .max_decimal_digits = 3 }), code, "must be a decimal number with 1 to 3 decimal places", "must be a decimal number with {min_decimal_digits} to {max_decimal_digits} decimal places");
    try expectPlaceholder(v.decimal(.{}), "{min_decimal_digits}", "1");
    try expectPlaceholder(v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 4 }), "{min_decimal_digits}", "2");
    try expectPlaceholder(v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 4 }), "{max_decimal_digits}", "4");
    try expectViolation([]const u8, v.decimal(.{}), "1.", code, "must be a decimal number", "x");
    try expectViolation([]const u8, v.decimal(.{ .max_decimal_digits = 2 }), "1.234", code, "must be a decimal number with at most 2 decimal places", "x");
    try expectNoViolation([]const u8, v.decimal(.{}), "+.5");
}

test "booleanString is a rule value with code validation.boolean_string and message \"must be true, false, 1 or 0\"" {
    try testing.expect(@hasDecl(v, "booleanString"));
    try testing.expect(@TypeOf(v.booleanString) == v.Rule);
    try expectRule(v.booleanString, "validation.boolean_string", "must be true, false, 1 or 0", "must be true, false, 1 or 0");
    try expectViolation([]const u8, v.booleanString, "TRUE", "validation.boolean_string", "must be true, false, 1 or 0", "x");
    try expectNoViolation([]const u8, v.booleanString, "false");
}

test "hexadecimal is a rule value with code validation.hexadecimal and message \"must be a hexadecimal number\"" {
    try testing.expect(@hasDecl(v, "hexadecimal"));
    try testing.expect(@TypeOf(v.hexadecimal) == v.Rule);
    try expectRule(v.hexadecimal, "validation.hexadecimal", "must be a hexadecimal number", "must be a hexadecimal number");
    try expectViolation([]const u8, v.hexadecimal, "0x", "validation.hexadecimal", "must be a hexadecimal number", "x");
    try expectNoViolation([]const u8, v.hexadecimal, "0xDEADbeef");
}

test "octal is a rule value with code validation.octal and message \"must be an octal number\"" {
    try testing.expect(@hasDecl(v, "octal"));
    try testing.expect(@TypeOf(v.octal) == v.Rule);
    try expectRule(v.octal, "validation.octal", "must be an octal number", "must be an octal number");
    try expectViolation([]const u8, v.octal, "0o8", "validation.octal", "must be an octal number", "x");
    try expectNoViolation([]const u8, v.octal, "0o755");
}

test "port is a rule value with code validation.port and message \"must be a port number from 0 to 65535\"" {
    try testing.expect(@hasDecl(v, "port"));
    try testing.expect(@TypeOf(v.port) == v.Rule);
    try expectRule(v.port, "validation.port", "must be a port number from 0 to 65535", "must be a port number from 0 to 65535");
    try expectViolation([]const u8, v.port, "65536", "validation.port", "must be a port number from 0 to 65535", "x");
    try expectNoViolation([]const u8, v.port, "0");
}

test "latitude is a rule value with code validation.latitude and message \"must be a latitude from -90 to 90\"" {
    try testing.expect(@hasDecl(v, "latitude"));
    try testing.expect(@TypeOf(v.latitude) == v.Rule);
    try expectRule(v.latitude, "validation.latitude", "must be a latitude from -90 to 90", "must be a latitude from -90 to 90");
    try expectViolation([]const u8, v.latitude, "90.1", "validation.latitude", "must be a latitude from -90 to 90", "x");
    try expectViolation(f64, v.latitude, -90.5, "validation.latitude", "must be a latitude from -90 to 90", "x");
    try expectNoViolation([]const u8, v.latitude, "-90.000");
    try expectNoViolation(f64, v.latitude, 90);
}

test "longitude is a rule value with code validation.longitude and message \"must be a longitude from -180 to 180\"" {
    try testing.expect(@hasDecl(v, "longitude"));
    try testing.expect(@TypeOf(v.longitude) == v.Rule);
    try expectRule(v.longitude, "validation.longitude", "must be a longitude from -180 to 180", "must be a longitude from -180 to 180");
    try expectViolation([]const u8, v.longitude, "-180.5", "validation.longitude", "must be a longitude from -180 to 180", "x");
    try expectViolation(f32, v.longitude, 180.5, "validation.longitude", "must be a longitude from -180 to 180", "x");
    try expectNoViolation([]const u8, v.longitude, "180.0");
    try expectNoViolation(f32, v.longitude, -180);
}

test "latLong is a rule value with code validation.lat_long and message \"must be a latitude,longitude pair\"" {
    try testing.expect(@hasDecl(v, "latLong"));
    try testing.expect(@TypeOf(v.latLong) == v.Rule);
    try expectRule(v.latLong, "validation.lat_long", "must be a latitude,longitude pair", "must be a latitude,longitude pair");
    try expectViolation([]const u8, v.latLong, "40.7128,\t-74.0060", "validation.lat_long", "must be a latitude,longitude pair", "x");
    try expectNoViolation([]const u8, v.latLong, "(40.7128, -74.0060)");
}

test "email is a rule value with code validation.email and message \"must be a valid email address\"" {
    try testing.expect(@hasDecl(v, "email"));
    try testing.expect(@TypeOf(v.email) == v.Rule);
    try expectRule(v.email, "validation.email", "must be a valid email address", "must be a valid email address");
    try expectViolation([]const u8, v.email, "user@example.c", "validation.email", "must be a valid email address", "x");
    try expectNoViolation([]const u8, v.email, "user@example.XN--P1AI");
}

test "httpUrl is a rule value with code validation.http_url and message \"must be a valid HTTP or HTTPS URL\"" {
    try testing.expect(@hasDecl(v, "httpUrl"));
    try testing.expect(@TypeOf(v.httpUrl) == v.Rule);
    try expectRule(v.httpUrl, "validation.http_url", "must be a valid HTTP or HTTPS URL", "must be a valid HTTP or HTTPS URL");
    try expectViolation([]const u8, v.httpUrl, "http://user@example.com", "validation.http_url", "must be a valid HTTP or HTTPS URL", "x");
    try expectNoViolation([]const u8, v.httpUrl, "https://example.com:8080/a?b=[1]#c");
}

test "fqdn is a rule constructor with code validation.fqdn and message \"must be a valid domain name\" whatever the options" {
    try testing.expect(@hasDecl(v, "fqdn"));
    try testing.expect(@typeInfo(@TypeOf(v.fqdn)).@"fn".return_type == v.Rule);
    try expectRule(v.fqdn(.{}), "validation.fqdn", "must be a valid domain name", "must be a valid domain name");
    try expectRule(v.fqdn(.{ .require_tld = false, .allow_underscores = true, .allow_trailing_dot = true, .allow_wildcard = true }), "validation.fqdn", "must be a valid domain name", "must be a valid domain name");
    try expectViolation([]const u8, v.fqdn(.{}), "localhost", "validation.fqdn", "must be a valid domain name", "x");
    try expectNoViolation([]const u8, v.fqdn(.{}), "example.com");
    try expectNoViolation([]const u8, v.fqdn(.{ .require_tld = false }), "localhost");
}

test "ip is a rule value with code validation.ip and message \"must be a valid IP address\"" {
    try testing.expect(@hasDecl(v, "ip"));
    try testing.expect(@TypeOf(v.ip) == v.Rule);
    try expectRule(v.ip, "validation.ip", "must be a valid IP address", "must be a valid IP address");
    try expectViolation([]const u8, v.ip, "fe80::1%eth0", "validation.ip", "must be a valid IP address", "x");
    try expectNoViolation([]const u8, v.ip, "192.0.2.1");
    try expectNoViolation([]const u8, v.ip, "::ffff:192.0.2.1");
}

test "ipv4 is a rule value with code validation.ipv4 and message \"must be a valid IPv4 address\"" {
    try testing.expect(@hasDecl(v, "ipv4"));
    try testing.expect(@TypeOf(v.ipv4) == v.Rule);
    try expectRule(v.ipv4, "validation.ipv4", "must be a valid IPv4 address", "must be a valid IPv4 address");
    try expectViolation([]const u8, v.ipv4, "192.168.1.01", "validation.ipv4", "must be a valid IPv4 address", "x");
    try expectNoViolation([]const u8, v.ipv4, "192.0.2.1");
}

test "ipv6 is a rule value with code validation.ipv6 and message \"must be a valid IPv6 address\"" {
    try testing.expect(@hasDecl(v, "ipv6"));
    try testing.expect(@TypeOf(v.ipv6) == v.Rule);
    try expectRule(v.ipv6, "validation.ipv6", "must be a valid IPv6 address", "must be a valid IPv6 address");
    try expectViolation([]const u8, v.ipv6, "1::2::3", "validation.ipv6", "must be a valid IPv6 address", "x");
    try expectNoViolation([]const u8, v.ipv6, "2001:db8::1");
}

test "macAddress is a rule constructor with code validation.mac_address and message \"must be a valid MAC address\", or one of 5 messages for other options" {
    try testing.expect(@hasDecl(v, "macAddress"));
    try testing.expect(@typeInfo(@TypeOf(v.macAddress)).@"fn".return_type == v.Rule);
    const code = "validation.mac_address";
    try expectRule(v.macAddress(.{}), code, "must be a valid MAC address", "must be a valid MAC address");
    try expectRule(v.macAddress(.{ .eui = .eui48 }), code, "must be a valid 48-bit MAC address", "must be a valid 48-bit MAC address");
    try expectRule(v.macAddress(.{ .eui = .eui64 }), code, "must be a valid 64-bit MAC address", "must be a valid 64-bit MAC address");
    try expectRule(v.macAddress(.{ .format = .bare }), code, "must be a MAC address of 12 or 16 hex digits without separators", "must be a MAC address of 12 or 16 hex digits without separators");
    try expectRule(v.macAddress(.{ .eui = .eui48, .format = .bare }), code, "must be a MAC address of 12 hex digits without separators", "must be a MAC address of 12 hex digits without separators");
    try expectRule(v.macAddress(.{ .eui = .eui64, .format = .bare }), code, "must be a MAC address of 16 hex digits without separators", "must be a MAC address of 16 hex digits without separators");
    try expectViolation([]const u8, v.macAddress(.{}), "00:00:5e-00:53:01", code, "must be a valid MAC address", "x");
    try expectViolation([]const u8, v.macAddress(.{ .eui = .eui64, .format = .bare }), "00005e005301", code, "must be a MAC address of 16 hex digits without separators", "x");
    try expectNoViolation([]const u8, v.macAddress(.{}), "00-00-5E-00-53-01");
}

test "json is a rule value with code validation.json and message \"must be a valid JSON object or array\"" {
    try testing.expect(@hasDecl(v, "json"));
    try testing.expect(@TypeOf(v.json) == v.Rule);
    try expectRule(v.json, "validation.json", "must be a valid JSON object or array", "must be a valid JSON object or array");
    try expectViolation([]const u8, v.json, "1", "validation.json", "must be a valid JSON object or array", "x");
    try expectNoViolation([]const u8, v.json, "{\"a\":[1]}");
}

test "jwt is a rule value with code validation.jwt and message \"must be a valid JWT\"" {
    try testing.expect(@hasDecl(v, "jwt"));
    try testing.expect(@TypeOf(v.jwt) == v.Rule);
    try expectRule(v.jwt, "validation.jwt", "must be a valid JWT", "must be a valid JWT");
    try expectViolation([]const u8, v.jwt, "e30.e30", "validation.jwt", "must be a valid JWT", "x");
    try expectNoViolation([]const u8, v.jwt, "e30.e30.e30");
}

test "base32 is a rule value with code validation.base32 and message \"must be valid base32\"" {
    try testing.expect(@hasDecl(v, "base32"));
    try testing.expect(@TypeOf(v.base32) == v.Rule);
    try expectRule(v.base32, "validation.base32", "must be valid base32", "must be valid base32");
    try expectViolation([]const u8, v.base32, "MZXW6YTBOI", "validation.base32", "must be valid base32", "x");
    try expectNoViolation([]const u8, v.base32, "MZXW6YTBOI======");
}

test "base58 is a rule value with code validation.base58 and message \"must be valid base58\"" {
    try testing.expect(@hasDecl(v, "base58"));
    try testing.expect(@TypeOf(v.base58) == v.Rule);
    try expectRule(v.base58, "validation.base58", "must be valid base58", "must be valid base58");
    try expectViolation([]const u8, v.base58, "0OIl", "validation.base58", "must be valid base58", "x");
    try expectNoViolation([]const u8, v.base58, "3yZe7d");
}

test "base64 is a rule value with code validation.base64 and message \"must be valid base64\"" {
    try testing.expect(@hasDecl(v, "base64"));
    try testing.expect(@TypeOf(v.base64) == v.Rule);
    try expectRule(v.base64, "validation.base64", "must be valid base64", "must be valid base64");
    try expectViolation([]const u8, v.base64, "Zg", "validation.base64", "must be valid base64", "x");
    try expectNoViolation([]const u8, v.base64, "Zg==");
}

test "base64Url is a rule value with code validation.base64_url and message \"must be valid base64url\"" {
    try testing.expect(@hasDecl(v, "base64Url"));
    try testing.expect(@TypeOf(v.base64Url) == v.Rule);
    try expectRule(v.base64Url, "validation.base64_url", "must be valid base64url", "must be valid base64url");
    try expectViolation([]const u8, v.base64Url, "Zg==", "validation.base64_url", "must be valid base64url", "x");
    try expectNoViolation([]const u8, v.base64Url, "Zg");
}

test "dataUri is a rule value with code validation.data_uri and message \"must be a valid data URI\"" {
    try testing.expect(@hasDecl(v, "dataUri"));
    try testing.expect(@TypeOf(v.dataUri) == v.Rule);
    try expectRule(v.dataUri, "validation.data_uri", "must be a valid data URI", "must be a valid data URI");
    try expectViolation([]const u8, v.dataUri, "data:text/plain", "validation.data_uri", "must be a valid data URI", "x");
    try expectNoViolation([]const u8, v.dataUri, "data:,A%20brief%20note");
}

test "magnetUri is a rule value with code validation.magnet_uri and message \"must be a valid magnet URI\"" {
    try testing.expect(@hasDecl(v, "magnetUri"));
    try testing.expect(@TypeOf(v.magnetUri) == v.Rule);
    try expectRule(v.magnetUri, "validation.magnet_uri", "must be a valid magnet URI", "must be a valid magnet URI");
    try expectViolation([]const u8, v.magnetUri, "magnet:?", "validation.magnet_uri", "must be a valid magnet URI", "x");
    try expectNoViolation([]const u8, v.magnetUri, "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a");
}

test "mimeType is a rule value with code validation.mime_type and message \"must be a valid MIME type\"" {
    try testing.expect(@hasDecl(v, "mimeType"));
    try testing.expect(@TypeOf(v.mimeType) == v.Rule);
    try expectRule(v.mimeType, "validation.mime_type", "must be a valid MIME type", "must be a valid MIME type");
    try expectViolation([]const u8, v.mimeType, "text", "validation.mime_type", "must be a valid MIME type", "x");
    try expectNoViolation([]const u8, v.mimeType, "application/json; charset=utf-8");
}

test "locale is a rule value with code validation.locale and message \"must be a valid locale\"" {
    try testing.expect(@hasDecl(v, "locale"));
    try testing.expect(@TypeOf(v.locale) == v.Rule);
    try expectRule(v.locale, "validation.locale", "must be a valid locale", "must be a valid locale");
    try expectViolation([]const u8, v.locale, "en_US", "validation.locale", "must be a valid locale", "x");
    try expectNoViolation([]const u8, v.locale, "en-US");
}

test "semVer is a rule value with code validation.sem_ver and message \"must be a valid semantic version\"" {
    try testing.expect(@hasDecl(v, "semVer"));
    try testing.expect(@TypeOf(v.semVer) == v.Rule);
    try expectRule(v.semVer, "validation.sem_ver", "must be a valid semantic version", "must be a valid semantic version");
    try expectViolation([]const u8, v.semVer, "v1.2.3", "validation.sem_ver", "must be a valid semantic version", "x");
    try expectNoViolation([]const u8, v.semVer, "1.2.3-alpha.1+build.5");
}

test "hexColor is a rule value with code validation.hex_color and message \"must be a valid hex color\"" {
    try testing.expect(@hasDecl(v, "hexColor"));
    try testing.expect(@TypeOf(v.hexColor) == v.Rule);
    try expectRule(v.hexColor, "validation.hex_color", "must be a valid hex color", "must be a valid hex color");
    try expectViolation([]const u8, v.hexColor, "fff", "validation.hex_color", "must be a valid hex color", "x");
    try expectNoViolation([]const u8, v.hexColor, "#ff0000");
}

test "rgbColor is a rule value with code validation.rgb_color and message \"must be a valid RGB color\"" {
    try testing.expect(@hasDecl(v, "rgbColor"));
    try testing.expect(@TypeOf(v.rgbColor) == v.Rule);
    try expectRule(v.rgbColor, "validation.rgb_color", "must be a valid RGB color", "must be a valid RGB color");
    try expectViolation([]const u8, v.rgbColor, "rgb(256,0,0)", "validation.rgb_color", "must be a valid RGB color", "x");
    try expectNoViolation([]const u8, v.rgbColor, "rgb(255, 0, 0)");
}

test "hslColor is a rule value with code validation.hsl_color and message \"must be a valid HSL color\"" {
    try testing.expect(@hasDecl(v, "hslColor"));
    try testing.expect(@TypeOf(v.hslColor) == v.Rule);
    try expectRule(v.hslColor, "validation.hsl_color", "must be a valid HSL color", "must be a valid HSL color");
    try expectViolation([]const u8, v.hslColor, "hsl(120,100,50%)", "validation.hsl_color", "must be a valid HSL color", "x");
    try expectNoViolation([]const u8, v.hslColor, "hsl(120 100% 50% / 0.5)");
}

test "uuid is a rule value with code validation.uuid and message \"must be a valid UUID\"; no precondition" {
    try testing.expect(@hasDecl(v, "uuid"));
    try testing.expect(@TypeOf(v.uuid) == v.Rule);
    try expectRule(v.uuid, "validation.uuid", "must be a valid UUID", "must be a valid UUID");
    try expectViolation([]const u8, v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf", "validation.uuid", "must be a valid UUID", "x");
    try expectViolation([]const u8, v.uuid.withMessage("another message"), "\xff", "validation.uuid", "another message", "x");
    try expectNoViolation([]const u8, v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
}

test "mongoId is a rule value with code validation.mongo_id and message \"must be a valid MongoDB ObjectId\"; no precondition" {
    try testing.expect(@hasDecl(v, "mongoId"));
    try testing.expect(@TypeOf(v.mongoId) == v.Rule);
    try expectRule(v.mongoId, "validation.mongo_id", "must be a valid MongoDB ObjectId", "must be a valid MongoDB ObjectId");
    try expectViolation([]const u8, v.mongoId, "0xaaaaaaaaaaaaaaaaaaaaaa", "validation.mongo_id", "must be a valid MongoDB ObjectId", "x");
    try expectViolation([]const u8, v.mongoId.withMessage("another message"), "\xff", "validation.mongo_id", "another message", "x");
    try expectNoViolation([]const u8, v.mongoId, "507f1f77bcf86cd799439011");
}

test "firebasePushId is a rule value with code validation.firebase_push_id and message \"must be a valid Firebase push ID\"; no precondition" {
    try testing.expect(@hasDecl(v, "firebasePushId"));
    try testing.expect(@TypeOf(v.firebasePushId) == v.Rule);
    try expectRule(v.firebasePushId, "validation.firebase_push_id", "must be a valid Firebase push ID", "must be a valid Firebase push ID");
    try expectViolation([]const u8, v.firebasePushId, "-JhLeOlGIEjaIOFHR0x", "validation.firebase_push_id", "must be a valid Firebase push ID", "x");
    try expectViolation([]const u8, v.firebasePushId.withMessage("another message"), "\xff", "validation.firebase_push_id", "another message", "x");
    try expectNoViolation([]const u8, v.firebasePushId, "-JhLeOlGIEjaIOFHR0xd");
}

test "hash is a rule constructor with code validation.hash and message \"must be a valid {algorithm} hash\" for each of its 13 algorithms; placeholder {algorithm}; no precondition" {
    try testing.expect(@hasDecl(v, "hash"));
    try testing.expect(@typeInfo(@TypeOf(v.hash)).@"fn".return_type == v.Rule);
    const algorithms = [_][]const u8{ "md4", "md5", "sha1", "sha256", "sha384", "sha512", "ripemd128", "ripemd160", "tiger128", "tiger160", "tiger192", "crc32", "crc32b" };
    try testing.expect(@typeInfo(v.HashAlgorithm).@"enum".mode == .exhaustive);
    try testing.expectEqual(algorithms.len, comptime std.meta.fieldNames(v.HashAlgorithm).len);
    inline for (algorithms, comptime std.meta.fieldNames(v.HashAlgorithm)) |name, tag| {
        try testing.expectEqualStrings(name, tag);
        const rule = v.hash(@field(v.HashAlgorithm, name));
        try expectRule(rule, "validation.hash", "must be a valid " ++ name ++ " hash", "must be a valid {algorithm} hash");
        try expectPlaceholder(rule, "{algorithm}", name);
    }
    try expectViolation([]const u8, v.hash(.sha256), "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha256 hash", "x");
    try expectViolation([]const u8, v.hash(.md5).withMessage("another message"), "\xff", "validation.hash", "another message", "x");
    try expectNoViolation([]const u8, v.hash(.md5), "d41d8cd98f00b204e9800998ecf8427e");
}

test "creditCard is a rule value with code validation.credit_card and message \"must be a valid credit card number\"; no precondition" {
    try testing.expect(@hasDecl(v, "creditCard"));
    try testing.expect(@TypeOf(v.creditCard) == v.Rule);
    try expectRule(v.creditCard, "validation.credit_card", "must be a valid credit card number", "must be a valid credit card number");
    try expectViolation([]const u8, v.creditCard, "4111111111111112", "validation.credit_card", "must be a valid credit card number", "x");
    try expectViolation([]const u8, v.creditCard.withMessage("another message"), "\xff", "validation.credit_card", "another message", "x");
    try expectNoViolation([]const u8, v.creditCard, "4111111111111111");
}

test "isbn is a rule value with code validation.isbn and message \"must be a valid ISBN\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn"));
    try testing.expect(@TypeOf(v.isbn) == v.Rule);
    try expectRule(v.isbn, "validation.isbn", "must be a valid ISBN", "must be a valid ISBN");
    try expectViolation([]const u8, v.isbn, "978-0-306-40615-7", "validation.isbn", "must be a valid ISBN", "x");
    try expectViolation([]const u8, v.isbn.withMessage("another message"), "\xff", "validation.isbn", "another message", "x");
    try expectNoViolation([]const u8, v.isbn, "9780306406157");
}

test "isbn10 is a rule value with code validation.isbn10 and message \"must be a valid ISBN-10\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn10"));
    try testing.expect(@TypeOf(v.isbn10) == v.Rule);
    try expectRule(v.isbn10, "validation.isbn10", "must be a valid ISBN-10", "must be a valid ISBN-10");
    try expectViolation([]const u8, v.isbn10, "9780306406157", "validation.isbn10", "must be a valid ISBN-10", "x");
    try expectViolation([]const u8, v.isbn10.withMessage("another message"), "\xff", "validation.isbn10", "another message", "x");
    try expectNoViolation([]const u8, v.isbn10, "0306406152");
}

test "isbn13 is a rule value with code validation.isbn13 and message \"must be a valid ISBN-13\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn13"));
    try testing.expect(@TypeOf(v.isbn13) == v.Rule);
    try expectRule(v.isbn13, "validation.isbn13", "must be a valid ISBN-13", "must be a valid ISBN-13");
    try expectViolation([]const u8, v.isbn13, "0306406152", "validation.isbn13", "must be a valid ISBN-13", "x");
    try expectViolation([]const u8, v.isbn13.withMessage("another message"), "\xff", "validation.isbn13", "another message", "x");
    try expectNoViolation([]const u8, v.isbn13, "9780306406157");
}

test "issn is a rule value with code validation.issn and message \"must be a valid ISSN\"; no precondition" {
    try testing.expect(@hasDecl(v, "issn"));
    try testing.expect(@TypeOf(v.issn) == v.Rule);
    try expectRule(v.issn, "validation.issn", "must be a valid ISSN", "must be a valid ISSN");
    try expectViolation([]const u8, v.issn, "03178471", "validation.issn", "must be a valid ISSN", "x");
    try expectViolation([]const u8, v.issn.withMessage("another message"), "\xff", "validation.issn", "another message", "x");
    try expectNoViolation([]const u8, v.issn, "0317-8471");
}

test "ean is a rule value with code validation.ean and message \"must be a valid EAN\"; no precondition" {
    try testing.expect(@hasDecl(v, "ean"));
    try testing.expect(@TypeOf(v.ean) == v.Rule);
    try expectRule(v.ean, "validation.ean", "must be a valid EAN", "must be a valid EAN");
    try expectViolation([]const u8, v.ean, "036000291452", "validation.ean", "must be a valid EAN", "x");
    try expectViolation([]const u8, v.ean.withMessage("another message"), "\xff", "validation.ean", "another message", "x");
    try expectNoViolation([]const u8, v.ean, "4006381333931");
}

test "isin is a rule value with code validation.isin and message \"must be a valid ISIN\"; no precondition" {
    try testing.expect(@hasDecl(v, "isin"));
    try testing.expect(@TypeOf(v.isin) == v.Rule);
    try expectRule(v.isin, "validation.isin", "must be a valid ISIN", "must be a valid ISIN");
    try expectViolation([]const u8, v.isin, "US0378331006", "validation.isin", "must be a valid ISIN", "x");
    try expectViolation([]const u8, v.isin.withMessage("another message"), "\xff", "validation.isin", "another message", "x");
    try expectNoViolation([]const u8, v.isin, "US0378331005");
}

test "isrc is a rule value with code validation.isrc and message \"must be a valid ISRC\"; no precondition" {
    try testing.expect(@hasDecl(v, "isrc"));
    try testing.expect(@TypeOf(v.isrc) == v.Rule);
    try expectRule(v.isrc, "validation.isrc", "must be a valid ISRC", "must be a valid ISRC");
    try expectViolation([]const u8, v.isrc, "US-RC1-76-07839", "validation.isrc", "must be a valid ISRC", "x");
    try expectViolation([]const u8, v.isrc.withMessage("another message"), "\xff", "validation.isrc", "another message", "x");
    try expectNoViolation([]const u8, v.isrc, "USRC17607839");
}

test "bic is a rule value with code validation.bic and message \"must be a valid BIC\"; no precondition" {
    try testing.expect(@hasDecl(v, "bic"));
    try testing.expect(@TypeOf(v.bic) == v.Rule);
    try expectRule(v.bic, "validation.bic", "must be a valid BIC", "must be a valid BIC");
    try expectViolation([]const u8, v.bic, "deutdeff", "validation.bic", "must be a valid BIC", "x");
    try expectViolation([]const u8, v.bic.withMessage("another message"), "\xff", "validation.bic", "another message", "x");
    try expectNoViolation([]const u8, v.bic, "DEUTDEFF");
}

test "iban is a rule value with code validation.iban and message \"must be a valid IBAN\"; no precondition" {
    try testing.expect(@hasDecl(v, "iban"));
    try testing.expect(@TypeOf(v.iban) == v.Rule);
    try expectRule(v.iban, "validation.iban", "must be a valid IBAN", "must be a valid IBAN");
    try expectViolation([]const u8, v.iban, "DE01370400441000000008", "validation.iban", "must be a valid IBAN", "x");
    try expectViolation([]const u8, v.iban.withMessage("another message"), "\xff", "validation.iban", "another message", "x");
    try expectNoViolation([]const u8, v.iban, "DE89370400440532013000");
}

test "btcAddress is a rule constructor with code validation.btc_address and message \"must be a valid Bitcoin address\", or \"must be a valid Bitcoin testnet address\" for .testnet; placeholder {network}; no precondition" {
    try testing.expect(@hasDecl(v, "btcAddress"));
    try testing.expect(@typeInfo(@TypeOf(v.btcAddress)).@"fn".return_type == v.Rule);
    const networks = [_][]const u8{ "mainnet", "testnet", "any" };
    try testing.expect(@typeInfo(v.BtcNetwork).@"enum".mode == .exhaustive);
    try testing.expectEqual(networks.len, comptime std.meta.fieldNames(v.BtcNetwork).len);
    inline for (networks, comptime std.meta.fieldNames(v.BtcNetwork)) |name, tag| try testing.expectEqualStrings(name, tag);
    try expectRule(v.btcAddress(.mainnet), "validation.btc_address", "must be a valid Bitcoin address", "must be a valid Bitcoin address");
    try expectRule(v.btcAddress(.any), "validation.btc_address", "must be a valid Bitcoin address", "must be a valid Bitcoin address");
    try expectRule(v.btcAddress(.testnet), "validation.btc_address", "must be a valid Bitcoin testnet address", "must be a valid Bitcoin testnet address");
    try expectPlaceholder(v.btcAddress(.mainnet), "{network}", "mainnet");
    try expectPlaceholder(v.btcAddress(.testnet), "{network}", "testnet");
    try expectPlaceholder(v.btcAddress(.any), "{network}", "any");
    try expectViolation([]const u8, v.btcAddress(.mainnet), "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "validation.btc_address", "must be a valid Bitcoin address", "x");
    try expectViolation([]const u8, v.btcAddress(.testnet), "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "validation.btc_address", "must be a valid Bitcoin testnet address", "x");
    try expectViolation([]const u8, v.btcAddress(.any).withMessage("another message"), "\xff", "validation.btc_address", "another message", "x");
    try expectNoViolation([]const u8, v.btcAddress(.any), "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4");
}

test "ethereumAddress is a rule value with code validation.ethereum_address and message \"must be a valid Ethereum address\"; no precondition" {
    try testing.expect(@hasDecl(v, "ethereumAddress"));
    try testing.expect(@TypeOf(v.ethereumAddress) == v.Rule);
    try expectRule(v.ethereumAddress, "validation.ethereum_address", "must be a valid Ethereum address", "must be a valid Ethereum address");
    try expectViolation([]const u8, v.ethereumAddress, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD", "validation.ethereum_address", "must be a valid Ethereum address", "x");
    try expectViolation([]const u8, v.ethereumAddress.withMessage("another message"), "\xff", "validation.ethereum_address", "another message", "x");
    try expectNoViolation([]const u8, v.ethereumAddress, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
}

test "date is a rule value with code validation.date and message \"must be a valid date in YYYY-MM-DD format\"" {
    try testing.expect(@hasDecl(v, "date"));
    try testing.expect(@TypeOf(v.date) == v.Rule);
    try expectRule(v.date, "validation.date", "must be a valid date in YYYY-MM-DD format", "must be a valid date in YYYY-MM-DD format");
    try expectViolation([]const u8, v.date, "2021-02-29", "validation.date", "must be a valid date in YYYY-MM-DD format", "x");
    try expectNoViolation([]const u8, v.date, "2020-02-29");
}

test "rfc3339 is a rule value with code validation.rfc3339 and message \"must be a valid RFC 3339 date-time\"" {
    try testing.expect(@hasDecl(v, "rfc3339"));
    try testing.expect(@TypeOf(v.rfc3339) == v.Rule);
    try expectRule(v.rfc3339, "validation.rfc3339", "must be a valid RFC 3339 date-time", "must be a valid RFC 3339 date-time");
    try expectViolation([]const u8, v.rfc3339, "2020-05-17T10:30:00", "validation.rfc3339", "must be a valid RFC 3339 date-time", "x");
    try expectNoViolation([]const u8, v.rfc3339, "2020-05-17T10:30:00Z");
}

test "iso8601 is a rule value with code validation.iso8601 and message \"must be a valid ISO 8601 date\"" {
    try testing.expect(@hasDecl(v, "iso8601"));
    try testing.expect(@TypeOf(v.iso8601) == v.Rule);
    try expectRule(v.iso8601, "validation.iso8601", "must be a valid ISO 8601 date", "must be a valid ISO 8601 date");
    try expectViolation([]const u8, v.iso8601, "2020-W00", "validation.iso8601", "must be a valid ISO 8601 date", "x");
    try expectNoViolation([]const u8, v.iso8601, "2020-W20-7");
}

/// A date-time bound whose default message would be longer than 512 bytes.
const long_date_time = "2020-01-01T00:00:00." ++ @as([600]u8, @splat('0')) ++ "Z";

test "minDate is a rule constructor with code validation.min_date and message \"must not be before {min}\", or \"must not be before the minimum date\" when that would be longer than 512 bytes; placeholder {min}" {
    try testing.expect(@hasDecl(v, "minDate"));
    try testing.expect(@typeInfo(@TypeOf(v.minDate)).@"fn".return_type == v.Rule);
    try expectRule(v.minDate("2020-01-01"), "validation.min_date", "must not be before 2020-01-01", "must not be before {min}");
    try expectPlaceholder(v.minDate("2020-01-01"), "{min}", "2020-01-01");
    try expectViolation([]const u8, v.minDate("2020-01-01"), "2019-12-31", "validation.min_date", "must not be before 2020-01-01", "x");
    try expectRule(v.minDate(long_date_time), "validation.min_date", "must not be before the minimum date", "must not be before the minimum date");
    try expectViolation([]const u8, v.minDate(long_date_time), "2019-12-31T23:59:59Z", "validation.min_date", "must not be before the minimum date", "x");
    try expectNoViolation([]const u8, v.minDate("2020-01-01"), "2020-01-01");
}

test "maxDate is a rule constructor with code validation.max_date and message \"must not be after {max}\", or \"must not be after the maximum date\" when that would be longer than 512 bytes; placeholder {max}" {
    try testing.expect(@hasDecl(v, "maxDate"));
    try testing.expect(@typeInfo(@TypeOf(v.maxDate)).@"fn".return_type == v.Rule);
    try expectRule(v.maxDate("2020-12-31"), "validation.max_date", "must not be after 2020-12-31", "must not be after {max}");
    try expectPlaceholder(v.maxDate("2020-12-31"), "{max}", "2020-12-31");
    try expectViolation([]const u8, v.maxDate("2020-12-31"), "2021-01-01", "validation.max_date", "must not be after 2020-12-31", "x");
    try expectRule(v.maxDate(long_date_time), "validation.max_date", "must not be after the maximum date", "must not be after the maximum date");
    try expectViolation([]const u8, v.maxDate(long_date_time), "2020-01-01T00:00:01Z", "validation.max_date", "must not be after the maximum date", "x");
    try expectNoViolation([]const u8, v.maxDate("2020-12-31"), "2020-12-31");
}

test "militaryTime is a rule value with code validation.military_time and message \"must be a valid time in 24-hour HH:MM format\"" {
    try testing.expect(@hasDecl(v, "militaryTime"));
    try testing.expect(@TypeOf(v.militaryTime) == v.Rule);
    try expectRule(v.militaryTime, "validation.military_time", "must be a valid time in 24-hour HH:MM format", "must be a valid time in 24-hour HH:MM format");
    try expectViolation([]const u8, v.militaryTime, "24:00", "validation.military_time", "must be a valid time in 24-hour HH:MM format", "x");
    try expectNoViolation([]const u8, v.militaryTime, "23:59");
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

test "uniqueItems is a rule value with code validation.unique_items and message \"must not contain duplicates\"" {
    try testing.expect(@hasDecl(v, "uniqueItems"));
    try testing.expect(@TypeOf(v.uniqueItems) == v.Rule);
    try expectRule(v.uniqueItems, "validation.unique_items", "must not contain duplicates", "must not contain duplicates");
    try expectViolation([]const u32, .{ v.maxItems(10), v.uniqueItems }, &.{ 1, 1 }, "validation.unique_items", "must not contain duplicates", "x");
    try expectNoViolation([]const u32, .{ v.maxItems(10), v.uniqueItems }, &.{ 1, 2 });
}

test "uniqueBy is a rule constructor with code validation.unique_items and message \"must not contain duplicate {key} values\"; placeholder {key}" {
    const Item = struct { id: u32 };
    try testing.expect(@hasDecl(v, "uniqueBy"));
    try testing.expect(@typeInfo(@TypeOf(v.uniqueBy)).@"fn".return_type == v.Rule);
    try expectRule(v.uniqueBy(.id), "validation.unique_items", "must not contain duplicate id values", "must not contain duplicate {key} values");
    try expectPlaceholder(v.uniqueBy(.id), "{key}", "id");
    try expectViolation([]const Item, .{ v.maxItems(10), v.uniqueBy(.id) }, &.{ .{ .id = 1 }, .{ .id = 1 } }, "validation.unique_items", "must not contain duplicate id values", "x");
    try expectNoViolation([]const Item, .{ v.maxItems(10), v.uniqueBy(.id) }, &.{ .{ .id = 1 }, .{ .id = 2 } });
}

test "containsAll is a rule constructor with code validation.contains_all and message \"must contain all of: {values}\", \"must contain {values}\" for one value, or \"must contain all of the required values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "containsAll"));
    try testing.expect(@typeInfo(@TypeOf(v.containsAll)).@"fn".return_type == v.Rule);
    try expectRule(v.containsAll(.{ "a", "b" }), "validation.contains_all", "must contain all of: a, b", "must contain all of: {values}");
    try expectPlaceholder(v.containsAll(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const []const u8, v.containsAll(.{ "a", "b" }), &.{"a"}, "validation.contains_all", "must contain all of: a, b", "x");
    try expectRule(v.containsAll(.{"a"}), "validation.contains_all", "must contain a", "must contain {values}");
    try expectPlaceholder(v.containsAll(.{"a"}), "{values}", "a");
    try expectViolation([]const []const u8, v.containsAll(.{"a"}), &.{"b"}, "validation.contains_all", "must contain a", "x");
    try expectRule(v.containsAll(long_values), "validation.contains_all", "must contain all of the required values", "must contain all of the required values");
    try expectViolation([]const []const u8, v.containsAll(long_values), &.{"c"}, "validation.contains_all", "must contain all of the required values", "x");
    try expectNoViolation([]const []const u8, v.containsAll(.{ "a", "b" }), &.{ "b", "a" });
}

test "containsNone is a rule constructor with code validation.contains_none and message \"must not contain any of: {values}\", \"must not contain {values}\" for one value, or \"must not contain any of the forbidden values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "containsNone"));
    try testing.expect(@typeInfo(@TypeOf(v.containsNone)).@"fn".return_type == v.Rule);
    try expectRule(v.containsNone(.{ "a", "b" }), "validation.contains_none", "must not contain any of: a, b", "must not contain any of: {values}");
    try expectPlaceholder(v.containsNone(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const []const u8, v.containsNone(.{ "a", "b" }), &.{"b"}, "validation.contains_none", "must not contain any of: a, b", "x");
    try expectRule(v.containsNone(.{"a"}), "validation.contains_none", "must not contain a", "must not contain {values}");
    try expectPlaceholder(v.containsNone(.{"a"}), "{values}", "a");
    try expectViolation([]const []const u8, v.containsNone(.{"a"}), &.{"a"}, "validation.contains_none", "must not contain a", "x");
    try expectRule(v.containsNone(long_values), "validation.contains_none", "must not contain any of the forbidden values", "must not contain any of the forbidden values");
    try expectViolation([]const []const u8, v.containsNone(long_values), &.{long_values[1]}, "validation.contains_none", "must not contain any of the forbidden values", "x");
    try expectNoViolation([]const []const u8, v.containsNone(.{ "a", "b" }), &.{"c"});
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

test "latitude on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.latitude, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.latitude, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.latitude, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.latitude.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.latitude.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.latitude.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "longitude on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.longitude, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.longitude, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.longitude, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.longitude.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.longitude.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.longitude.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
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

test "minDate fails a value without the form of its bound with the date-form precondition, also under withMessage" {
    try expectViolation([]const u8, v.minDate("2020-01-01"), "2020-01-01T00:00:00Z", "validation.date", "must be a valid date in YYYY-MM-DD format", "x");
    try expectViolation([]const u8, v.minDate("2020-01-01").withMessage("another message"), "", "validation.date", "must be a valid date in YYYY-MM-DD format", "x");
    try expectViolation([]const u8, v.minDate("2020-01-01T00:00:00Z"), "2020-01-01", "validation.rfc3339", "must be a valid RFC 3339 date-time", "x");
    try expectViolation([]const u8, v.minDate("2020-01-01T00:00:00Z").withMessage("another message"), "", "validation.rfc3339", "must be a valid RFC 3339 date-time", "x");
}

test "maxDate fails a value without the form of its bound with the date-form precondition, also under withMessage" {
    try expectViolation([]const u8, v.maxDate("2020-12-31"), "2020-12-31T00:00:00Z", "validation.date", "must be a valid date in YYYY-MM-DD format", "x");
    try expectViolation([]const u8, v.maxDate("2020-12-31").withMessage("another message"), "", "validation.date", "must be a valid date in YYYY-MM-DD format", "x");
    try expectViolation([]const u8, v.maxDate("2020-12-31T23:59:59Z"), "2020-12-31", "validation.rfc3339", "must be a valid RFC 3339 date-time", "x");
    try expectViolation([]const u8, v.maxDate("2020-12-31T23:59:59Z").withMessage("another message"), "", "validation.rfc3339", "must be a valid RFC 3339 date-time", "x");
}

test "the module exports exactly its 190 public names, and Rule.withMessage" {
    const names = [_][]const u8{
        "Violation",             "Rule",              "Report",         "max_code_bytes", "max_message_bytes", "max_report_violations", "max_unique_items", "max_json_depth",
        "check",                 "checkAll",          "assertRules",    "fail",           "equals",            "notEquals",             "oneOf",            "noneOf",
        "empty",                 "notEmpty",          "min",            "max",            "range",             "positive",              "nonNegative",      "negative",
        "nonPositive",           "divisibleBy",       "finite",         "minLength",      "maxLength",         "length",                "minBytes",         "maxBytes",
        "utf8",                  "notBlank",          "ascii",          "printableAscii", "alphanumeric",      "alpha",                 "digits",           "lowercase",
        "uppercase",             "multibyte",         "fullWidth",      "halfWidth",      "variableWidth",     "contains",              "notContains",      "strongPassword",
        "StrongPasswordOptions", "isUtf8",            "isNotBlank",     "isAscii",        "isPrintableAscii",  "isAlphanumeric",        "isAlpha",          "isDigits",
        "isLowercase",           "isUppercase",       "isMultibyte",    "isFullWidth",    "isHalfWidth",       "isVariableWidth",       "isStrongPassword", "numberString",
        "decimal",               "booleanString",     "hexadecimal",    "octal",          "port",              "latitude",              "longitude",        "latLong",
        "email",                 "httpUrl",           "fqdn",           "ip",             "ipv4",              "ipv6",                  "macAddress",       "DecimalOptions",
        "FqdnOptions",           "MacAddressOptions", "isNumberString", "isDecimal",      "isBooleanString",   "isHexadecimal",         "isOctal",          "isPort",
        "isLatitude",            "isLongitude",       "isLatLong",      "isEmail",        "isHttpUrl",         "isFqdn",                "isIp",             "isIpv4",
        "isIpv6",                "isMacAddress",      "json",           "isJson",         "jwt",               "isJwt",                 "base32",           "isBase32",
        "base58",                "isBase58",          "base64",         "isBase64",       "base64Url",         "isBase64Url",           "dataUri",          "isDataUri",
        "magnetUri",             "isMagnetUri",       "mimeType",       "isMimeType",     "locale",            "isLocale",              "semVer",           "isSemVer",
        "hexColor",              "isHexColor",        "rgbColor",       "isRgbColor",     "hslColor",          "isHslColor",            "uuid",             "mongoId",
        "firebasePushId",        "hash",              "creditCard",     "isbn",           "isbn10",            "isbn13",                "issn",             "ean",
        "isin",                  "isrc",              "bic",            "iban",           "btcAddress",        "ethereumAddress",       "isUuid",           "isMongoId",
        "isFirebasePushId",      "isHash",            "isCreditCard",   "isIsbn",         "isIsbn10",          "isIsbn13",              "isIssn",           "isEan",
        "isIsin",                "isIsrc",            "isBic",          "isIban",         "isBtcAddress",      "isEthereumAddress",     "HashAlgorithm",    "BtcNetwork",
        "date",                  "isDate",            "rfc3339",        "isRfc3339",      "iso8601",           "isIso8601",             "minDate",          "maxDate",
        "militaryTime",          "isMilitaryTime",    "minItems",       "maxItems",       "uniqueItems",       "uniqueBy",              "containsAll",      "containsNone",
        "each",                  "custom",            "transform",      "TransformError", "rename",            "nameOf",                "fieldNamed",       "trim",
        "trimStart",             "trimEnd",           "toLower",        "toUpper",        "transformWith",     "closest",
    };
    inline for (names) |name| try testing.expect(@hasDecl(v, name));
    try testing.expectEqual(names.len, comptime std.meta.declarations(v).len);
    try testing.expect(@hasDecl(v.Rule, "withMessage"));
}

test "every rule the module exports has a catalog test" {
    // Comparing every exported name with every listed one takes more
    // comptime branches than a test allows by default.
    @setEvalBranchQuota(100_000);
    const tested = [_][]const u8{
        "equals",        "notEquals",       "oneOf",       "noneOf",         "empty",          "notEmpty",     "min",           "max",
        "range",         "positive",        "nonNegative", "negative",       "nonPositive",    "divisibleBy",  "finite",        "minLength",
        "maxLength",     "length",          "minBytes",    "maxBytes",       "utf8",           "notBlank",     "ascii",         "printableAscii",
        "alphanumeric",  "alpha",           "digits",      "lowercase",      "uppercase",      "multibyte",    "fullWidth",     "halfWidth",
        "variableWidth", "contains",        "notContains", "strongPassword", "numberString",   "decimal",      "booleanString", "hexadecimal",
        "octal",         "port",            "latitude",    "longitude",      "latLong",        "email",        "httpUrl",       "fqdn",
        "ip",            "ipv4",            "ipv6",        "macAddress",     "json",           "jwt",          "base32",        "base58",
        "base64",        "base64Url",       "dataUri",     "magnetUri",      "mimeType",       "locale",       "semVer",        "hexColor",
        "rgbColor",      "hslColor",        "uuid",        "mongoId",        "firebasePushId", "hash",         "creditCard",    "isbn",
        "isbn10",        "isbn13",          "issn",        "ean",            "isin",           "isrc",         "bic",           "iban",
        "btcAddress",    "ethereumAddress", "date",        "rfc3339",        "iso8601",        "minDate",      "maxDate",       "militaryTime",
        "minItems",      "maxItems",        "uniqueItems", "uniqueBy",       "containsAll",    "containsNone", "each",          "custom",
    };
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
    const predicates = [_][]const u8{
        "isUtf8",          "isNotBlank",    "isAscii",      "isPrintableAscii",  "isAlphanumeric",  "isAlpha",          "isDigits",         "isLowercase",
        "isUppercase",     "isMultibyte",   "isFullWidth",  "isHalfWidth",       "isVariableWidth", "isStrongPassword", "isNumberString",   "isDecimal",
        "isBooleanString", "isHexadecimal", "isOctal",      "isPort",            "isLatitude",      "isLongitude",      "isLatLong",        "isEmail",
        "isHttpUrl",       "isFqdn",        "isIp",         "isIpv4",            "isIpv6",          "isMacAddress",     "isJson",           "isJwt",
        "isBase32",        "isBase58",      "isBase64",     "isBase64Url",       "isDataUri",       "isMagnetUri",      "isMimeType",       "isLocale",
        "isSemVer",        "isHexColor",    "isRgbColor",   "isHslColor",        "isUuid",          "isMongoId",        "isFirebasePushId", "isHash",
        "isCreditCard",    "isIsbn",        "isIsbn10",     "isIsbn13",          "isIssn",          "isEan",            "isIsin",           "isIsrc",
        "isBic",           "isIban",        "isBtcAddress", "isEthereumAddress", "isDate",          "isRfc3339",        "isIso8601",        "isMilitaryTime",
    };
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

test "the predicates have their catalog signatures: the input first, the options last" {
    const plain = [_][]const u8{
        "isNumberString", "isBooleanString", "isHexadecimal", "isOctal", "isPort", "isLatitude", "isLongitude", "isLatLong",
        "isEmail",        "isHttpUrl",       "isIp",          "isIpv4",  "isIpv6",
    };
    inline for (plain) |name| try testing.expect(@TypeOf(@field(v, name)) == fn ([]const u8) bool);
    try testing.expect(@TypeOf(v.isDecimal) == fn ([]const u8, v.DecimalOptions) bool);
    try testing.expect(@TypeOf(v.isFqdn) == fn ([]const u8, v.FqdnOptions) bool);
    try testing.expect(@TypeOf(v.isMacAddress) == fn ([]const u8, v.MacAddressOptions) bool);
}

/// The fields of the struct `T` are `names`, in this order, of these types.
fn expectFields(comptime T: type, comptime names: []const []const u8, comptime types: []const type) !void {
    const info = @typeInfo(T).@"struct";
    try testing.expectEqual(names.len, info.field_names.len);
    inline for (names, types, info.field_names, info.field_types) |name, Expected, field_name, Field| {
        try testing.expectEqualStrings(name, field_name);
        try testing.expect(Field == Expected);
    }
}

/// The tags of the enum `E` are `names`, in this order.
fn expectTags(comptime E: type, comptime names: []const []const u8) !void {
    const info = @typeInfo(E).@"enum";
    try testing.expectEqual(names.len, info.field_names.len);
    inline for (names, info.field_names) |name, tag| try testing.expectEqualStrings(name, tag);
}

test "the options of decimal, fqdn and macAddress have their catalog fields, in order, with their defaults" {
    try expectFields(v.DecimalOptions, &.{ "force_decimal", "min_decimal_digits", "max_decimal_digits" }, &.{ bool, usize, ?usize });
    const decimal_defaults: v.DecimalOptions = .{};
    try testing.expectEqual(false, decimal_defaults.force_decimal);
    try testing.expectEqual(1, decimal_defaults.min_decimal_digits);
    try testing.expectEqual(null, decimal_defaults.max_decimal_digits);
    try expectFields(v.FqdnOptions, &.{ "require_tld", "allow_underscores", "allow_trailing_dot", "allow_wildcard" }, &.{ bool, bool, bool, bool });
    const fqdn_defaults: v.FqdnOptions = .{};
    try testing.expectEqual(true, fqdn_defaults.require_tld);
    try testing.expectEqual(false, fqdn_defaults.allow_underscores);
    try testing.expectEqual(false, fqdn_defaults.allow_trailing_dot);
    try testing.expectEqual(false, fqdn_defaults.allow_wildcard);
    try expectFields(v.MacAddressOptions, &.{ "eui", "format" }, &.{ v.MacAddressOptions.Eui, v.MacAddressOptions.Format });
    const mac_defaults: v.MacAddressOptions = .{};
    try testing.expectEqual(v.MacAddressOptions.Eui.any, mac_defaults.eui);
    try testing.expectEqual(v.MacAddressOptions.Format.separated, mac_defaults.format);
    try expectTags(v.MacAddressOptions.Eui, &.{ "any", "eui48", "eui64" });
    try expectTags(v.MacAddressOptions.Format, &.{ "separated", "bare" });
}

test "the predicates of the identifier rules have their catalog signatures" {
    inline for (.{ v.isUuid, v.isMongoId, v.isFirebasePushId, v.isCreditCard, v.isIsbn, v.isIsbn10, v.isIsbn13, v.isIssn, v.isEan, v.isIsin, v.isIsrc, v.isBic, v.isIban, v.isEthereumAddress }) |predicate| {
        try testing.expect(@TypeOf(predicate) == fn ([]const u8) bool);
    }
    try testing.expect(@TypeOf(v.isHash) == fn ([]const u8, v.HashAlgorithm) bool);
    try testing.expect(@TypeOf(v.isBtcAddress) == fn ([]const u8, v.BtcNetwork) bool);
}

test "the limits have their catalog values" {
    try testing.expect(@TypeOf(v.max_code_bytes) == comptime_int);
    try testing.expectEqual(128, v.max_code_bytes);
    try testing.expect(@TypeOf(v.max_message_bytes) == comptime_int);
    try testing.expectEqual(512, v.max_message_bytes);
    try testing.expect(@TypeOf(v.max_report_violations) == comptime_int);
    try testing.expectEqual(100, v.max_report_violations);
    try testing.expect(@TypeOf(v.max_unique_items) == comptime_int);
    try testing.expectEqual(1000, v.max_unique_items);
    try testing.expect(@TypeOf(v.max_json_depth) == comptime_int);
    try testing.expectEqual(64, v.max_json_depth);
}
