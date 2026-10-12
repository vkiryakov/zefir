//! String rules: the length of a string in code points (`minLength`,
//! `maxLength`, `length`) or in bytes (`minBytes`, `maxBytes`). A string is a
//! slice of u8 (`core.isString`). The rules that count code points validate
//! the whole value first and fail invalid UTF-8 with the precondition
//! `validation.utf8` / "must be valid UTF-8"; the byte rules never decode.
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ field types

/// The field-type check of a rule that takes strings and gives no hint of
/// its own.
fn stringFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (stringProblem(rule, T, where, null)) |text| @compileError(text);
}

/// The declaration error of a string rule on the unwrapped field type `T`,
/// or null: the field is a string. `hint` follows the text unless a hint of
/// the core applies (`[N]u8`, a list of strings, an odd slice).
fn stringProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8, comptime hint: ?[]const u8) ?[]const u8 {
    if (core.isString(T)) return null;
    return core.typeErrorText(rule, T, where, "a string", core.isString, hint);
}

/// The field-type check of `minLength`, `maxLength` and `length`: on a slice
/// of other items the hint names the list rules with the same counts (an
/// array has a fixed length, so it gets none).
fn lengthFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    const hint = if (core.isListSlice(T)) core.hints.itemCount(rule.*) else null;
    if (stringProblem(rule, T, where, hint)) |text| @compileError(text);
}

// ------------------------------------------------------------------ minLength, maxLength, length

/// At least `min` code points (Unicode scalar values); `min` is at least 1.
/// Every code point counts as one character, with no trimming, no Unicode
/// normalization and no grapheme clusters: `"e\u{301}"` and
/// `"\u{2764}\u{FE0F}"` are 2 characters. Invalid UTF-8 fails with the
/// precondition `validation.utf8`, checked first even when the number of
/// bytes alone would decide. Its placeholder is `{min}`.
pub fn minLength(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.min_length, min)) |text| @compileError(text);
    return codePointRule(.min_length, min, null, core.renderArg(min), "must be at least " ++ core.plural(min, "character", "characters"), &.{core.param("min", min)});
}

/// At most `max` code points, counted as `minLength` counts them; `max` is
/// at least 1 (for no characters use `v.empty`). Invalid UTF-8 fails with the
/// precondition `validation.utf8`. Its placeholder is `{max}`.
pub fn maxLength(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.max_length, max)) |text| @compileError(text);
    return codePointRule(.max_length, null, max, core.renderArg(max), "must be at most " ++ core.plural(max, "character", "characters"), &.{core.param("max", max)});
}

/// From `min` to `max` code points, counted as `minLength` counts them;
/// `1 <= min <= max`, and equal bounds ask for an exact length ("must be
/// exactly 5 characters"). Invalid UTF-8 fails with the precondition
/// `validation.utf8`. Its placeholders are `{min}` and `{max}`.
pub fn length(comptime min: usize, comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (lengthCallProblem(min, max)) |text| @compileError(text);
    const message = if (min == max)
        "must be exactly " ++ core.plural(min, "character", "characters")
    else
        "must be from " ++ core.renderValue(min) ++ " to " ++ core.renderValue(max) ++ " characters";
    return codePointRule(.length, min, max, core.renderArg(min) ++ ", " ++ core.renderArg(max), message, &.{ core.param("min", min), core.param("max", max) });
}

/// The error of the call `minLength(n)`, `maxLength(n)`, `minBytes(n)` or
/// `maxBytes(n)`, or null: the count is at least 1.
fn boundCallProblem(comptime kind: core.Kind, comptime n: usize) ?[]const u8 {
    if (n != 0) return null;
    return switch (kind) {
        .min_length => "validator: minLength(0): min must be at least 1 (minLength(0) is always true; " ++ core.hints.use_utf8 ++ ")",
        .max_length => "validator: maxLength(0): max must be at least 1; " ++ core.hints.use_empty,
        .min_bytes => "validator: minBytes(0): min must be at least 1 (minBytes(0) is always true; remove it)",
        .max_bytes => "validator: maxBytes(0): max must be at least 1; " ++ core.hints.use_empty,
        else => @compileError("validator: internal: " ++ @tagName(kind) ++ " is not a string bound rule"),
    };
}

/// The error of the call `length(min, max)`, or null: `1 <= min <= max`.
fn lengthCallProblem(comptime min: usize, comptime max: usize) ?[]const u8 {
    if (min != 0 and min <= max) return null;
    const head = "validator: length(" ++ core.renderArg(min) ++ ", " ++ core.renderArg(max) ++ "): ";
    if (min == 0) return head ++ "min must be at least 1; " ++ if (max == 0) core.hints.use_empty else core.hints.useMaxLength(max);
    return head ++ "min is greater than max";
}

/// A rule of `kind` that keeps strings of `lo` to `hi` code points; null
/// stands for no bound on that side.
fn codePointRule(comptime kind: core.Kind, comptime lo: ?usize, comptime hi: ?usize, comptime args: []const u8, comptime message: []const u8, comptime params: []const core.Param) Rule {
    return core.define(kind, .{
        .message = message,
        .args = args,
        .params = params,
        .precondition = core.preconditions.utf8,
        .fits = lengthFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                // It validates while it counts and fails exactly on the
                // inputs that utf8ValidateSlice rejects.
                const count = std.unicode.utf8CountCodepoints(value.*) catch return .precondition;
                if (comptime lo) |bound| {
                    if (count < bound) return .fail;
                }
                if (comptime hi) |bound| {
                    if (count > bound) return .fail;
                }
                return .pass;
            }
        }.eval,
    });
}

// ------------------------------------------------------------------ minBytes, maxBytes

/// At least `min` bytes: the length of the slice, without decoding, so an
/// invalid byte counts as one; `min` is at least 1. Its placeholder is
/// `{min}`.
pub fn minBytes(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.min_bytes, min)) |text| @compileError(text);
    return byteRule(.min_bytes, min, "must be at least " ++ core.plural(min, "byte", "bytes"), "min");
}

/// At most `max` bytes, without decoding; `max` is at least 1 (for no bytes
/// use `v.empty`). Put first in a tuple, it rejects a long value before rules
/// that read the whole string. Its placeholder is `{max}`.
pub fn maxBytes(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.max_bytes, max)) |text| @compileError(text);
    return byteRule(.max_bytes, max, "must be at most " ++ core.plural(max, "byte", "bytes"), "max");
}

/// `minBytes(n)` or `maxBytes(n)`, whose count is the placeholder `name`.
fn byteRule(comptime kind: core.Kind, comptime n: usize, comptime message: []const u8, comptime name: []const u8) Rule {
    return core.define(kind, .{
        .message = message,
        .args = core.renderArg(n),
        .params = &.{core.param(name, n)},
        .fits = stringFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(if (kind == .min_bytes) value.*.len >= n else value.*.len <= n);
            }
        }.eval,
    });
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `minLength must be called, e.g. v.minLength(1)`.
pub const call_examples = .{
    .minLength = "1",
    .maxLength = "100",
    .length = "1, 100",
    .minBytes = "1",
    .maxBytes = "100",
};

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// The declaration error of `rule` on a field of type `T`, or null.
fn fitsText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return switch (rule.kind) {
        .min_length, .max_length, .length => stringProblem(&rule, T, test_where, if (core.isListSlice(T)) core.hints.itemCount(rule) else null),
        else => stringProblem(&rule, T, test_where, null),
    };
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "the length rules have their documented codes, messages, parameters and the utf8 precondition" {
    const t = std.testing;
    const at_least = minLength(3);
    try t.expectEqual(core.Kind.min_length, at_least.kind);
    try t.expectEqualStrings("validation.min_length", at_least.code);
    try t.expectEqualStrings("must be at least 3 characters", at_least.message);
    try t.expectEqualStrings("3", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("3", at_least.params[0].text);
    try t.expect(comptime at_least.params[0].value.int == 3);
    try t.expectEqualStrings("validation.utf8", at_least.precondition.?.code);
    try t.expectEqualStrings("must be valid UTF-8", at_least.precondition.?.message);
    try t.expectEqualStrings("minLength(3)", comptime at_least.call());
    try t.expectEqualStrings("min_length(3)", comptime at_least.label());

    const at_most = maxLength(64);
    try t.expectEqual(core.Kind.max_length, at_most.kind);
    try t.expectEqualStrings("validation.max_length", at_most.code);
    try t.expectEqualStrings("must be at most 64 characters", at_most.message);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("64", at_most.params[0].text);
    try t.expectEqualStrings("validation.utf8", at_most.precondition.?.code);

    const between = length(3, 32);
    try t.expectEqual(core.Kind.length, between.kind);
    try t.expectEqualStrings("validation.length", between.code);
    try t.expectEqualStrings("must be from 3 to 32 characters", between.message);
    try t.expectEqualStrings("3, 32", between.args.?);
    try t.expectEqual(2, between.params.len);
    try t.expectEqualStrings("min", between.params[0].name);
    try t.expectEqualStrings("max", between.params[1].name);
    try t.expectEqualStrings("32", between.params[1].text);
    try t.expectEqualStrings("validation.utf8", between.precondition.?.code);
    try t.expectEqualStrings("length(3, 32)", comptime between.call());

    // One character is singular; equal bounds ask for an exact length.
    try t.expectEqualStrings("must be at least 1 character", minLength(1).message);
    try t.expectEqualStrings("must be at most 1 character", maxLength(1).message);
    try t.expectEqualStrings("must be exactly 5 characters", length(5, 5).message);
    try t.expectEqualStrings("must be exactly 1 character", length(1, 1).message);
    try t.expectEqualStrings("must be from 1 to 2 characters", length(1, 2).message);
    try t.expectEqualStrings("must be at most 18446744073709551615 characters", maxLength(std.math.maxInt(u64)).message);
}

test "minBytes and maxBytes have their documented codes, messages and parameters and no precondition" {
    const t = std.testing;
    const at_least = minBytes(8);
    try t.expectEqual(core.Kind.min_bytes, at_least.kind);
    try t.expectEqualStrings("validation.min_bytes", at_least.code);
    try t.expectEqualStrings("must be at least 8 bytes", at_least.message);
    try t.expectEqualStrings("8", at_least.args.?);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqual(null, at_least.precondition);
    try t.expectEqualStrings("min_bytes(8)", comptime at_least.label());

    const at_most = maxBytes(255);
    try t.expectEqual(core.Kind.max_bytes, at_most.kind);
    try t.expectEqualStrings("validation.max_bytes", at_most.code);
    try t.expectEqualStrings("must be at most 255 bytes", at_most.message);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("255", at_most.params[0].text);
    try t.expectEqual(null, at_most.precondition);

    try t.expectEqualStrings("must be at least 1 byte", minBytes(1).message);
    try t.expectEqualStrings("must be at most 1 byte", maxBytes(1).message);
}

test "the length and byte rules take a count of at least 1; length takes min <= max" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: minLength(0): min must be at least 1 (minLength(0) is always true; use v.utf8 to require valid UTF-8)", comptime boundCallProblem(.min_length, 0).?);
    try expect("validator: maxLength(0): max must be at least 1; use v.empty", comptime boundCallProblem(.max_length, 0).?);
    try expect("validator: minBytes(0): min must be at least 1 (minBytes(0) is always true; remove it)", comptime boundCallProblem(.min_bytes, 0).?);
    try expect("validator: maxBytes(0): max must be at least 1; use v.empty", comptime boundCallProblem(.max_bytes, 0).?);
    try expect("validator: length(0, 5): min must be at least 1; use v.maxLength(5)", comptime lengthCallProblem(0, 5).?);
    try expect("validator: length(0, 0): min must be at least 1; use v.empty", comptime lengthCallProblem(0, 0).?);
    try expect("validator: length(5, 3): min is greater than max", comptime lengthCallProblem(5, 3).?);
    inline for (.{ .min_length, .max_length, .min_bytes, .max_bytes }) |kind| {
        try std.testing.expectEqual(null, comptime boundCallProblem(kind, 1));
        try std.testing.expectEqual(null, comptime boundCallProblem(kind, std.math.maxInt(usize)));
    }
    try std.testing.expectEqual(null, comptime lengthCallProblem(1, 1));
    try std.testing.expectEqual(null, comptime lengthCallProblem(1, std.math.maxInt(usize)));
}

test "the length and byte rules take strings; [N]u8, lists of strings and odd slices get their hints" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "min_bytes expects a string, field is u32", comptime fitsText(minBytes(8), u32).?);
    try expect(head ++ "max_length expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(maxLength(64), [4]u8).?);
    try expect(head ++ "max_bytes expects a string, field is []const []const u8; use v.each(v.maxBytes(255))", comptime fitsText(maxBytes(255), []const []const u8).?);
    try expect(head ++ "length expects a string, field is [2]?[]const u8; use v.each(v.length(1, 2))", comptime fitsText(length(1, 2), [2]?[]const u8).?);
    try expect(head ++ "min_bytes expects a string, field is []const u32", comptime fitsText(minBytes(8), []const u32).?);
    try expect(head ++ "min_length expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fitsText(minLength(1), []volatile u8).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        inline for (.{ minLength(1), maxLength(1), length(1, 2), minBytes(1), maxBytes(1) }) |rule| {
            try std.testing.expectEqual(null, comptime fitsText(rule, T));
        }
    }
}

test "minLength, maxLength and length on a slice of other items name the list rules; an array gets no hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "min_length expects a string, field is []const u32; for the number of items use v.minItems(3)", comptime fitsText(minLength(3), []const u32).?);
    try expect(head ++ "max_length expects a string, field is []const u32; for the number of items use v.maxItems(64)", comptime fitsText(maxLength(64), []const u32).?);
    try expect(head ++ "length expects a string, field is []const u32; for the number of items use v.minItems(3) and v.maxItems(32)", comptime fitsText(length(3, 32), []const u32).?);
    try expect(head ++ "min_length expects a string, field is []const []const u8; use v.each(v.minLength(3))", comptime fitsText(minLength(3), []const []const u8).?);
    try expect(head ++ "length expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(length(3, 32), [4]u8).?);
    try expect(head ++ "max_length expects a string, field is [3]u32", comptime fitsText(maxLength(64), [3]u32).?);
    try expect(head ++ "min_length expects a string, field is u32", comptime fitsText(minLength(3), u32).?);
}

test "an uncalled length or byte rule gets an example call, and inside each the head is each(...)" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: minLength must be called, e.g. v.minLength(1)", comptime uncalledText("minLength", @TypeOf(minLength)));
    try expect("validator: Dto.field_rules.x: maxLength must be called, e.g. v.maxLength(100)", comptime uncalledText("maxLength", @TypeOf(maxLength)));
    try expect("validator: Dto.field_rules.x: length must be called, e.g. v.length(1, 100)", comptime uncalledText("length", @TypeOf(length)));
    try expect("validator: Dto.field_rules.x: minBytes must be called, e.g. v.minBytes(1)", comptime uncalledText("minBytes", @TypeOf(minBytes)));
    try expect("validator: Dto.field_rules.x: maxBytes must be called, e.g. v.maxBytes(100)", comptime uncalledText("maxBytes", @TypeOf(maxBytes)));
    try expect("validator: each(...): minLength must be called, e.g. v.minLength(1)", "validator: each(...): " ++ comptime core.hints.mustBeCalled("minLength", @TypeOf(minLength)));
}

test "the length rules count code points after the utf8 precondition" {
    try expectOutcome(.fail, minLength(2), @as([]const u8, "a"));
    try expectOutcome(.pass, minLength(2), @as([]const u8, "\u{E9}\u{E9}"));
    try expectOutcome(.fail, minLength(3), @as([]const u8, "\u{1F600}"));
    try expectOutcome(.pass, maxLength(1), @as([]const u8, "\u{1F600}"));
    try expectOutcome(.fail, maxLength(1), @as([]const u8, "e\u{301}"));
    try expectOutcome(.pass, maxLength(1), @as([]const u8, ""));
    try expectOutcome(.fail, minLength(1), @as([]const u8, ""));
    try expectOutcome(.pass, length(2, 2), @as([:0]const u8, "\u{2764}\u{FE0F}"));
    try expectOutcome(.precondition, minLength(3), @as([]const u8, "\xff"));
    try expectOutcome(.precondition, maxLength(100), @as([]const u8, "\xff"));
    try expectOutcome(.precondition, length(1, 5), @as([]const u8, "abc\xe6\x97"));
}

test "minBytes and maxBytes read the length of the slice and never decode" {
    try expectOutcome(.pass, minBytes(3), @as([]const u8, "\xed\xa0\x80"));
    try expectOutcome(.fail, minBytes(2), @as([]const u8, "\xff"));
    try expectOutcome(.pass, maxBytes(3), @as([]const u8, "\xff\xff\xff"));
    try expectOutcome(.fail, maxBytes(2), @as([]const u8, "\xff\xff\xff"));
    try expectOutcome(.fail, maxBytes(8), @as([]const u8, "日本語"));
    try expectOutcome(.pass, maxBytes(9), @as([]const u8, "日本語"));
}
