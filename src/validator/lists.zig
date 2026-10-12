//! List rules: `minItems`, `maxItems` and `each`. A list is a slice whose
//! items are not `u8`, or an array `[N]T` (`[N]u8` included: it is an array
//! of numbers).
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

fn acceptsList(comptime T: type) bool {
    return core.ListChild(T) != null;
}

// ------------------------------------------------------------------ minItems, maxItems

/// `len >= min` on a slice: items are counted, null items included, never
/// checked. `min` is at least 1 (`minItems(0)` is always true). `v.notEmpty`
/// says the same as `minItems(1)` with its own code: prefer `v.notEmpty`
/// unless clients branch on `validation.min_items`. A fixed-size array `[N]T`
/// is a compile error: its length never changes.
pub fn minItems(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.min_items, min)) |text| @compileError(text);
    return countRule(.min_items, min, "must have at least " ++ core.plural(min, "item", "items"), "min");
}

/// `len <= max` on a slice, null items included. `max` is at least 1: for
/// no items use `v.empty`. A fixed-size array `[N]T` is a compile error.
pub fn maxItems(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.max_items, max)) |text| @compileError(text);
    return countRule(.max_items, max, "must have at most " ++ core.plural(max, "item", "items"), "max");
}

/// The error of the call `minItems(n)` or `maxItems(n)`, or null: the count
/// is at least 1.
fn countCallProblem(comptime kind: core.Kind, comptime n: usize) ?[]const u8 {
    if (n != 0) return null;
    return switch (kind) {
        .min_items => "validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)",
        .max_items => "validator: maxItems(0): max must be at least 1; " ++ core.hints.use_empty,
        else => @compileError("validator: internal: " ++ @tagName(kind) ++ " is not a count rule"),
    };
}

/// `minItems(n)` or `maxItems(n)`, whose count is the placeholder `name`.
fn countRule(comptime kind: core.Kind, comptime n: usize, comptime message: []const u8, comptime name: []const u8) Rule {
    return core.define(kind, .{
        .message = message,
        .args = core.renderArg(n),
        .params = &.{core.param(name, n)},
        .fits = countFits(n),
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(if (kind == .min_items) value.*.len >= n else value.*.len <= n);
            }
        }.eval,
    });
}

/// The field-type check of `minItems(n)` and `maxItems(n)`.
fn countFits(comptime n: usize) fn (comptime *const Rule, comptime type, comptime []const u8) void {
    return struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (countProblem(rule, n, T, where)) |text| @compileError(text);
        }
    }.fits;
}

/// The declaration error of `minItems(n)` or `maxItems(n)` on the unwrapped
/// field type `T`, or null: the field is a slice that is not a string. On a
/// fixed-size array the verdict never changes, so the error says which it
/// is; a string field gets the string rules as the hint.
fn countProblem(comptime rule: *const Rule, comptime n: usize, comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = if (rule.kind == .min_items) a.len >= n else a.len <= n;
            return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++ ": the length of an array is fixed");
        },
        else => {},
    }
    if (core.isListSlice(T)) return null;
    const strings = if (rule.kind == .min_items) core.hints.min_items_on_string else core.hints.max_items_on_string;
    return core.typeErrorText(rule, T, where, "a slice", core.isListSlice, if (core.isString(T)) strings else null);
}

// ------------------------------------------------------------------ each

/// The rules for every item of a slice or an array: one rule or a tuple of
/// rules. It declares item rules rather than checking the list: it must be
/// the last rule of its tuple and appear once, and it has no code or message
/// of its own. Null items are skipped; item paths are `tags[3]`.
pub fn each(comptime rules: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const inner = core.toRules(rules, "each(...)");
    if (inner.len == 0) @compileError("validator: each(.{}): the list is empty");
    return .{
        .kind = .each,
        .code = "",
        .message = "",
        .args = "...",
        .inner = inner,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                const Item = core.ListChild(T) orelse core.typeError(rule, T, where, "a slice or an array", acceptsList, null);
                core.checkRuleList(rule.inner, core.Unwrap(Item), where ++ "[]");
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                _ = value;
                @compileError("validator: internal: each is applied by the walker and never evaluated");
            }
        }.eval,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `each must be called, e.g. v.each(v.notEmpty)`.
pub const call_examples = .{ .minItems = "1", .maxItems = "100", .each = "v.notEmpty" };

const expectOutcome = core.expectOutcome;

/// A struct for the tests below.
const Record = struct { id: u32 };

const test_where = "Dto.field_rules.x";

/// The declaration error of `minItems(n)` or `maxItems(n)` on a field of
/// type `T`, or null.
fn minItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&minItems(n), n, T, test_where);
}

fn maxItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&maxItems(n), n, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "minItems and maxItems have their documented codes, messages and count parameters and no precondition" {
    const t = std.testing;
    const at_least = minItems(2);
    try t.expectEqual(core.Kind.min_items, at_least.kind);
    try t.expectEqualStrings("validation.min_items", at_least.code);
    try t.expectEqualStrings("must have at least 2 items", at_least.message);
    try t.expectEqualStrings("2", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("2", at_least.params[0].text);
    try t.expect(at_least.params[0].placeholder);
    try t.expect(comptime at_least.params[0].value.int == 2);
    try t.expectEqual(null, at_least.precondition);
    try t.expectEqualStrings("minItems(2)", comptime at_least.call());
    try t.expectEqualStrings("min_items(2)", comptime at_least.label());

    const at_most = maxItems(100);
    try t.expectEqual(core.Kind.max_items, at_most.kind);
    try t.expectEqualStrings("validation.max_items", at_most.code);
    try t.expectEqualStrings("must have at most 100 items", at_most.message);
    try t.expectEqualStrings("100", at_most.args.?);
    try t.expectEqual(1, at_most.params.len);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("100", at_most.params[0].text);
    try t.expect(at_most.params[0].placeholder);
    try t.expectEqual(null, at_most.precondition);
    try t.expectEqualStrings("max_items(100)", comptime at_most.label());

    // One item is singular; counts are decimal at every size.
    try t.expectEqualStrings("must have at least 1 item", minItems(1).message);
    try t.expectEqualStrings("must have at most 1 item", maxItems(1).message);
    try t.expectEqualStrings("must have at most 18446744073709551615 items", maxItems(std.math.maxInt(u64)).message);
}

test "minItems and maxItems take a count of at least 1" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)", comptime countCallProblem(.min_items, 0).?);
    try expect("validator: maxItems(0): max must be at least 1; use v.empty", comptime countCallProblem(.max_items, 0).?);
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.max_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, std.math.maxInt(usize)));
}

test "minItems and maxItems on a fixed-size array are errors: its length never changes" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const fixed = ": the length of an array is fixed";
    try expect(head ++ "min_items(1) on [3]u32 is always true" ++ fixed, comptime minItemsText(1, [3]u32).?);
    try expect(head ++ "min_items(3) on [3]u32 is always true" ++ fixed, comptime minItemsText(3, [3]u32).?);
    try expect(head ++ "min_items(4) on [3]u32 is always false" ++ fixed, comptime minItemsText(4, [3]u32).?);
    try expect(head ++ "min_items(1) on [0]u32 is always false" ++ fixed, comptime minItemsText(1, [0]u32).?);
    try expect(head ++ "max_items(2) on [3]u32 is always false" ++ fixed, comptime maxItemsText(2, [3]u32).?);
    try expect(head ++ "max_items(3) on [3]u32 is always true" ++ fixed, comptime maxItemsText(3, [3]u32).?);
    try expect(head ++ "max_items(1) on [0]u32 is always true" ++ fixed, comptime maxItemsText(1, [0]u32).?);
    try expect(head ++ "min_items(2) on [3:0]u32 is always true" ++ fixed, comptime minItemsText(2, [3:0]u32).?);
    try expect(head ++ "max_items(1) on [2][]const u8 is always false" ++ fixed, comptime maxItemsText(1, [2][]const u8).?);
    // [N]u8 is an array too; these rules take no strings, so no string hint follows.
    try expect(head ++ "min_items(1) on [4]u8 is always true" ++ fixed, comptime minItemsText(1, [4]u8).?);
}

test "minItems and maxItems take slices; a string field gets the string rules as the hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const min_strings = "; for strings use v.minLength or v.minBytes";
    const max_strings = "; for strings use v.maxLength or v.maxBytes";
    try expect(head ++ "min_items expects a slice, field is []const u8" ++ min_strings, comptime minItemsText(1, []const u8).?);
    try expect(head ++ "min_items expects a slice, field is [:0]u8" ++ min_strings, comptime minItemsText(1, [:0]u8).?);
    try expect(head ++ "max_items expects a slice, field is []const u8" ++ max_strings, comptime maxItemsText(3, []const u8).?);
    try expect(head ++ "max_items expects a slice, field is []u8" ++ max_strings, comptime maxItemsText(3, []u8).?);
    try expect(head ++ "min_items expects a slice, field is u32", comptime minItemsText(1, u32).?);
    try expect(head ++ "max_items expects a slice, field is u32", comptime maxItemsText(3, u32).?);
    try expect(head ++ "min_items expects a slice, field is lists.Record", comptime minItemsText(1, Record).?);
    try expect(head ++ "max_items expects a slice, field is *const [3]u32", comptime maxItemsText(3, *const [3]u32).?);
    try expect(
        head ++ "min_items expects a slice, field is []volatile u32; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime minItemsText(1, []volatile u32).?,
    );
    inline for (.{ []const u32, []u32, [:0]const u32, []const ?u32, []const []const u8, [][]u32, []const Record, []const f64 }) |T| {
        try std.testing.expectEqual(null, comptime minItemsText(1, T));
        try std.testing.expectEqual(null, comptime maxItemsText(1, T));
    }
}

test "an uncalled minItems or maxItems gets an example call, and inside each the head is each(...)" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: minItems must be called, e.g. v.minItems(1)", comptime uncalledText("minItems", @TypeOf(minItems)));
    try expect("validator: Dto.field_rules.x: maxItems must be called, e.g. v.maxItems(100)", comptime uncalledText("maxItems", @TypeOf(maxItems)));
    // each checks its argument when it is called, before the field is known.
    try expect("validator: each(...): minItems must be called, e.g. v.minItems(1)", "validator: each(...): " ++ comptime core.hints.mustBeCalled("minItems", @TypeOf(minItems)));
}

test "minItems and maxItems count the items of a slice, null items included" {
    try expectOutcome(.fail, minItems(2), @as([]const u32, &.{1}));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2, 3 }));
    try expectOutcome(.fail, minItems(1), @as([]const []const u8, &.{}));
    try expectOutcome(.pass, minItems(1), @as([]const ?u32, &.{null}));
    try expectOutcome(.pass, maxItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.fail, maxItems(2), @as([]const ?u32, &.{ null, null, null }));
    try expectOutcome(.pass, maxItems(1), @as([]const u32, &.{}));
    try expectOutcome(.pass, maxItems(std.math.maxInt(usize)), @as([]const u32, &.{ 1, 2 }));
}
