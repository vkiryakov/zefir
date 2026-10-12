//! Common rules: `equals`, `notEquals`, `empty` and `notEmpty`.
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ equals, notEquals

/// `value == expected`. Integers and bools compare exactly at every width;
/// floats by IEEE `==` after the parameter is rounded to the field type, so
/// -0.0 equals 0 and `equals(0.1)` on f32 accepts the f32 nearest to 0.1,
/// with no epsilon (NaN and infinities fail with the precondition
/// `validation.finite`); an enum by its tag, so an unnamed value of a
/// non-exhaustive enum never matches; strings byte for byte, with no
/// decoding, trimming or case folding. The parameter is one integer, finite
/// float, bool, named enum tag or non-empty valid UTF-8 string, and must fit
/// the field type. The message shows it as written: `v.equals(.admin)` says
/// "must be equal to admin".
pub fn equals(comptime expected: anytype) Rule {
    return comparison(.equals, expected);
}

/// `value != forbidden`, with the parameters and comparisons of `equals`.
/// On a float field NaN and infinities fail with the precondition, so
/// `notEquals(0)` does not pass them; an unnamed value of a non-exhaustive
/// enum always passes.
pub fn notEquals(comptime forbidden: anytype) Rule {
    return comparison(.not_equals, forbidden);
}

/// `equals(x)` or `notEquals(x)`.
fn comparison(comptime kind: core.Kind, comptime x: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (comparisonProblem(kind, x)) |text| @compileError(text);
    const is_equals = kind == .equals;
    return core.define(kind, .{
        .message = (if (is_equals) "must be equal to " else "must not be equal to ") ++ core.renderValue(x),
        .fallback = if (is_equals) "must be equal to the expected value" else "must not be equal to the forbidden value",
        .args = core.renderArg(x),
        .params = &.{core.param(if (is_equals) "expected" else "forbidden", x)},
        .precondition = core.preconditions.finite,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (scalarProblem(rule, x, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                const same = if (comptime core.isString(T)) std.mem.eql(u8, value.*, x) else switch (@typeInfo(T)) {
                    .float => blk: {
                        if (!std.math.isFinite(value.*)) return .precondition;
                        break :blk value.* == comptime core.valueAs(T, x);
                    },
                    .int, .bool, .@"enum" => value.* == comptime core.valueAs(T, x),
                    else => @compileError("validator: internal: " ++ @tagName(kind) ++ "'s eval was instantiated for a type its fits rejected"),
                };
                return core.passIf(same == is_equals);
            }
        }.eval,
    });
}

/// The error of the call `equals(x)` or `notEquals(x)`, or null: `x` is an
/// integer, a finite float, a bool, a named enum tag or a non-empty valid
/// UTF-8 string.
fn comparisonProblem(comptime kind: core.Kind, comptime x: anytype) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const X = @TypeOf(x);
    const shown = core.renderArg(x);
    const head = "validator: " ++ core.info(kind).name ++ "(" ++ shown ++ "): ";
    switch (comptime core.valueKind(X)) {
        .int, .bool => return null,
        .float => return if (core.isFiniteNumber(x)) null else head ++ shown ++ " is not finite",
        .tag => return if (core.tagName(x) != null) null else head ++ shown ++ " is not a named tag of " ++ @typeName(X),
        .string => {
            if (x.len == 0) return head ++ if (kind == .equals)
                "the expected value is the empty string; " ++ core.hints.use_empty
            else
                "the forbidden value is the empty string; " ++ core.hints.use_not_empty;
            if (!std.unicode.utf8ValidateSlice(x)) return head ++ shown ++ " is not valid UTF-8";
            return null;
        },
        .list, .other => return head ++ "expects an integer, a float, a bool, an enum tag or a string, got " ++ @typeName(X),
    }
}

/// The declaration error of `equals(x)` or `notEquals(x)` on the unwrapped
/// field type `T`, or null. A number field takes a number that fits it
/// (`numberParamProblem`), a bool field a bool, an enum field one of its
/// tags (and not a single-tag exhaustive enum, where the rule would be
/// decided), a string field a string; other fields are a type error, with
/// the `each` hint for a list whose items take a parameter of this kind.
fn scalarProblem(comptime rule: *const Rule, comptime x: anytype, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const kind = comptime core.valueKind(@TypeOf(x));
    const is_equals = rule.kind == .equals;
    if (core.isNumber(T)) {
        const outside = if (is_equals) "; the rule would never pass" else "; the rule would always pass";
        const text = core.numberParamProblem(x, T, "use an integer", outside) orelse return null;
        return core.ruleErrorText(rule, where, text);
    }
    if (T == bool) return if (kind == .bool) null else core.ruleErrorText(rule, where, wrongParamText(x, T, "use true or false"));
    if (@typeInfo(T) == .@"enum") {
        const e = @typeInfo(T).@"enum";
        if (kind != .tag) {
            const hint = if (e.field_names.len == 0) null else "use a tag such as ." ++ e.field_names[0];
            return core.ruleErrorText(rule, where, wrongParamText(x, T, hint));
        }
        if (core.tagProblem(x, T)) |text| return core.ruleErrorText(rule, where, text);
        if (e.mode == .exhaustive and e.field_names.len == 1)
            return core.ruleErrorText(rule, where, ": " ++ @typeName(T) ++ " has a single tag; the rule would " ++ (if (is_equals) "always" else "never") ++ " pass");
        return null;
    }
    if (core.isString(T)) return if (kind == .string) null else core.ruleErrorText(rule, where, wrongParamText(x, T, "use a string"));
    return core.typeErrorText(rule, T, where, "a number, a bool, an enum or a string", scalarAccepts(kind), null);
}

/// The field types that `equals` and `notEquals` take with a parameter of
/// `kind`: numbers for a number, bool for a bool, enums for a tag, strings
/// for a string. It picks the type error's hint.
fn scalarAccepts(comptime kind: core.ValueKind) fn (comptime type) bool {
    return struct {
        fn accepts(comptime F: type) bool {
            return switch (kind) {
                .int, .float => core.isNumber(F),
                .bool => F == bool,
                .tag => @typeInfo(F) == .@"enum",
                .string => core.isString(F),
                .list, .other => false,
            };
        }
    }.accepts;
}

/// A parameter of the wrong kind for the field, as the text after the rule's
/// label: `: "admin" is a string, field is Role; use a tag such as .admin`.
fn wrongParamText(comptime x: anytype, comptime T: type, comptime hint: ?[]const u8) []const u8 {
    return ": " ++ core.renderArg(x) ++ " is " ++ core.describeValueType(@TypeOf(x)) ++ ", field is " ++ @typeName(T) ++
        if (hint) |h| "; " ++ h else "";
}

// ------------------------------------------------------------------ empty, notEmpty

/// `len == 0`. Strings count bytes without decoding them, so `" "`,
/// `"\x00"`, `"\xff"` and U+200B are not empty; slices count items, null
/// items included. On a fixed-size array `[N]T` it is a compile error: the
/// length of an array never changes.
pub const empty: Rule = core.define(.empty, .{
    .message = "must be empty",
    .fits = lengthFits,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            return core.passIf(value.*.len == 0);
        }
    }.eval,
});

/// `len > 0`. Strings count bytes without decoding them, so `" "` and
/// `"\xff"` pass; slices count items, null items included. On a fixed-size
/// array `[N]T` it is a compile error: the length of an array never changes.
pub const notEmpty: Rule = core.define(.not_empty, .{
    .message = "must not be empty",
    .fits = lengthFits,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            return core.passIf(value.*.len != 0);
        }
    }.eval,
});

/// The field-type check of the length rules.
fn lengthFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (lengthProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `empty` or `notEmpty` on the unwrapped field
/// type `T`, or null: a string or a slice that is not a string. On a
/// fixed-size array the rule's verdict never changes, so it is an error,
/// with the hint that `[N]u8` is not a string.
fn lengthProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = (a.len == 0) == (rule.kind == .empty);
            return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++
                ": the length of an array is fixed" ++ (if (a.child == u8) "; " ++ core.hints.u8_array else ""));
        },
        else => {},
    }
    if (core.isString(T) or core.isListSlice(T)) return null;
    return core.typeErrorText(rule, T, where, "a string or a slice", struct {
        fn accepts(comptime F: type) bool {
            return core.isString(F) or core.isListSlice(F);
        }
    }.accepts, null);
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `equals must be called, e.g. v.equals(true)`.
pub const call_examples = .{ .equals = "true", .notEquals = "0" };

const expectOutcome = core.expectOutcome;

test "notEmpty has its documented code and message and no precondition" {
    try std.testing.expectEqualStrings("validation.not_empty", notEmpty.code);
    try std.testing.expectEqualStrings("must not be empty", notEmpty.message);
    try std.testing.expectEqual(core.Kind.not_empty, notEmpty.kind);
    try std.testing.expectEqual(null, notEmpty.args);
    try std.testing.expectEqual(null, notEmpty.precondition);
}

test "notEmpty counts the bytes of a string without decoding them" {
    try expectOutcome(.fail, notEmpty, @as([]const u8, ""));
    try expectOutcome(.pass, notEmpty, @as([]const u8, " "));
    try expectOutcome(.pass, notEmpty, @as([]const u8, "\xff"));
    try expectOutcome(.pass, notEmpty, @as([]const u8, "a"));
    try expectOutcome(.fail, notEmpty, @as([:0]const u8, ""));
    var buffer = "x".*;
    try expectOutcome(.pass, notEmpty, @as([]u8, &buffer));
    try expectOutcome(.fail, notEmpty, @as([]u8, buffer[0..0]));
}

test "notEmpty counts the items of a slice, null items included" {
    try expectOutcome(.fail, notEmpty, @as([]const u32, &.{}));
    try expectOutcome(.pass, notEmpty, @as([]const u32, &.{0}));
    try expectOutcome(.pass, notEmpty, @as([]const ?u32, &.{null}));
    try expectOutcome(.pass, notEmpty, @as([]const []const u8, &.{""}));
}

test "notEmpty fits strings of every kind and slices" {
    comptime {
        for ([_]type{ []const u8, []u8, [:0]const u8, [:0]u8, []const u32, []u32, []const ?u32, []const []const u8 }) |T| {
            notEmpty.fits(&notEmpty, T, "Dto.field_rules.x");
        }
    }
}

/// Types for the tests below: an exhaustive enum, another enum with a tag
/// of the same name, a non-exhaustive enum, single-tag enums, sparse tag
/// values, an enum without named tags and a struct.
const Role = enum { admin, user, guest };
const Color = enum { red, admin };
const Open = enum(u8) { a, b, _ };
const OpenOne = enum(u8) { only, _ };
const Only = enum { only };
const Sparse = enum(u32) { low = 1, high = 1_000_000 };
const NoTags = enum(u8) { _ };
const Item = struct { id: u32 };

const test_where = "Dto.field_rules.x";

/// The declaration error of `equals(x)` on a field of type `T`, or null.
fn equalsText(comptime x: anytype, comptime T: type) ?[]const u8 {
    return scalarProblem(&equals(x), x, T, test_where);
}

fn notEqualsText(comptime x: anytype, comptime T: type) ?[]const u8 {
    return scalarProblem(&notEquals(x), x, T, test_where);
}

/// The declaration error of `empty` or `notEmpty` on a field of type `T`, or null.
fn lengthText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return lengthProblem(&rule, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "equals and notEquals have their documented codes, messages, parameters and the finite precondition" {
    const t = std.testing;
    const same = equals(5);
    try t.expectEqual(core.Kind.equals, same.kind);
    try t.expectEqualStrings("validation.equals", same.code);
    try t.expectEqualStrings("must be equal to 5", same.message);
    try t.expectEqualStrings("5", same.args.?);
    try t.expectEqual(1, same.params.len);
    try t.expectEqualStrings("expected", same.params[0].name);
    try t.expectEqualStrings("5", same.params[0].text);
    try t.expect(same.params[0].placeholder);
    try t.expectEqualStrings("validation.finite", same.precondition.?.code);
    try t.expectEqualStrings("must be a finite number", same.precondition.?.message);

    const other = notEquals("root");
    try t.expectEqual(core.Kind.not_equals, other.kind);
    try t.expectEqualStrings("validation.not_equals", other.code);
    try t.expectEqualStrings("must not be equal to root", other.message);
    try t.expectEqualStrings("\"root\"", other.args.?);
    try t.expectEqual(1, other.params.len);
    try t.expectEqualStrings("forbidden", other.params[0].name);
    try t.expectEqualStrings("root", other.params[0].text);
    try t.expectEqualStrings("root", other.params[0].value.string);
    try t.expectEqualStrings("validation.finite", other.precondition.?.code);
}

test "equals and notEquals show the parameter as written: -0.0 as 0, floats as written, tags by name, strings escaped" {
    const expect = std.testing.expectEqualStrings;
    try expect("must be equal to 0", equals(-0.0).message);
    try expect("equals(0)", comptime equals(-0.0).call());
    try expect("must be equal to 0.1", equals(@as(f32, 0.1)).message);
    try expect("must be equal to 1e-7", equals(1e-7).message);
    try expect("must be equal to -170141183460469231731687303715884105728", equals(std.math.minInt(i128)).message);
    try expect("must not be equal to false", notEquals(false).message);
    try expect("must be equal to admin", equals(.admin).message);
    try expect("equals(.admin)", comptime equals(.admin).call());
    try expect("must be equal to guest", equals(Role.guest).message);
    try expect("must be equal to tab\\there", equals("tab\there").message);
    try expect("equals(\"tab\\there\")", comptime equals("tab\there").call());
    try expect("must not be equal to \\xe2\\x80\\xa8", notEquals("\u{2028}").message);
    try expect("must be equal to имя", equals("имя").message);
    try expect("not_equals(.only)", comptime notEquals(.only).label());
}

test "equals and notEquals keep a default message of exactly 512 bytes and take the fallback above it" {
    const t = std.testing;
    // "must be equal to " is 17 bytes, "must not be equal to " 21.
    const fits: [495]u8 = @splat('x');
    const over: [496]u8 = @splat('x');
    try t.expectEqual(512, equals(&fits).message.len);
    try t.expectEqualStrings("must be equal to " ++ fits, equals(&fits).message);
    try t.expectEqualStrings("must be equal to the expected value", equals(&over).message);
    const fits_not: [491]u8 = @splat('x');
    const over_not: [492]u8 = @splat('x');
    try t.expectEqual(512, notEquals(&fits_not).message.len);
    try t.expectEqualStrings("must not be equal to the forbidden value", notEquals(&over_not).message);
    // The parameter counts as the message shows it: 248 quotes are 496 bytes escaped.
    const quotes: [248]u8 = @splat('"');
    try t.expectEqualStrings("must be equal to the expected value", equals(&quotes).message);
    // Only the message falls back: the parameter keeps its whole text.
    try t.expectEqualStrings(&over, equals(&over).params[0].text);
    try t.expectEqualStrings("\"" ++ over ++ "\"", equals(&over).args.?);
}

test "equals and notEquals take one integer, finite float, bool, named tag or non-empty valid UTF-8 string" {
    const expect = std.testing.expectEqualStrings;
    const kinds = "expects an integer, a float, a bool, an enum tag or a string, got ";
    try expect("validator: equals(\"\"): the expected value is the empty string; use v.empty", comptime comparisonProblem(.equals, "").?);
    try expect("validator: notEquals(\"\"): the forbidden value is the empty string; use v.notEmpty", comptime comparisonProblem(.not_equals, "").?);
    try expect("validator: equals(\"\\xff\"): \"\\xff\" is not valid UTF-8", comptime comparisonProblem(.equals, "\xff").?);
    try expect("validator: notEquals(\"\\xff\"): \"\\xff\" is not valid UTF-8", comptime comparisonProblem(.not_equals, "\xff").?);
    try expect("validator: equals(\"caf\\xc3\"): \"caf\\xc3\" is not valid UTF-8", comptime comparisonProblem(.equals, "caf\xc3").?);
    try expect("validator: equals(nan): nan is not finite", comptime comparisonProblem(.equals, std.math.nan(f64)).?);
    try expect("validator: notEquals(nan): nan is not finite", comptime comparisonProblem(.not_equals, std.math.nan(f64)).?);
    try expect("validator: equals(inf): inf is not finite", comptime comparisonProblem(.equals, std.math.inf(f64)).?);
    try expect("validator: notEquals(-inf): -inf is not finite", comptime comparisonProblem(.not_equals, -std.math.inf(f32)).?);
    try expect("validator: equals(inf): inf is not finite", comptime comparisonProblem(.equals, @as(comptime_float, std.math.inf(f64))).?);
    try expect("validator: equals(...): " ++ kinds ++ "@TypeOf(null)", comptime comparisonProblem(.equals, null).?);
    try expect("validator: notEquals(...): " ++ kinds ++ "@TypeOf(null)", comptime comparisonProblem(.not_equals, null).?);
    try expect("validator: equals(...): " ++ kinds ++ "?u8", comptime comparisonProblem(.equals, @as(?u8, 5)).?);
    try expect("validator: equals(...): " ++ kinds ++ "common.Item", comptime comparisonProblem(.equals, Item{ .id = 1 }).?);
    try expect("validator: equals(...): " ++ kinds ++ "[]const u32", comptime comparisonProblem(.equals, @as([]const u32, &.{ 1, 2 })).?);
    try expect("validator: equals(.{ 1, 2 }): " ++ kinds ++ "[2]u32", comptime comparisonProblem(.equals, [_]u32{ 1, 2 }).?);
    try expect("validator: equals(@fromBackingInt(7)): @fromBackingInt(7) is not a named tag of common.Open", comptime comparisonProblem(.equals, @as(Open, @fromBackingInt(7))).?);
    try expect("validator: notEquals(@fromBackingInt(7)): @fromBackingInt(7) is not a named tag of common.Open", comptime comparisonProblem(.not_equals, @as(Open, @fromBackingInt(7))).?);
    inline for (.{ 0, -1, @as(u8, 5), std.math.maxInt(u128), 0.5, -0.0, @as(f16, 0.1), std.math.floatMax(f64), true, false, .admin, Role.guest, Open.a, "a", @as([]const u8, "x"), "имя" }) |x| {
        try std.testing.expectEqual(null, comptime comparisonProblem(.equals, x));
        try std.testing.expectEqual(null, comptime comparisonProblem(.not_equals, x));
    }
}

test "on an integer field the parameter of equals and notEquals is an integer within the field type" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(300): 300 is outside u8 (0..255); the rule would never pass", comptime equalsText(300, u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(-1): -1 is outside u32 (0..4294967295); the rule would always pass", comptime notEqualsText(-1, u32).?);
    try expect("validator: Dto.field_rules.x: equals(-129): -129 is outside i8 (-128..127); the rule would never pass", comptime equalsText(-129, i8).?);
    try expect("validator: Dto.field_rules.x: equals(1.5): 1.5 is a float (comptime_float), field is i32; use an integer", comptime equalsText(1.5, i32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1.5): 1.5 is a float (comptime_float), field is i32; use an integer", comptime notEqualsText(1.5, i32).?);
    try expect("validator: Dto.field_rules.x: equals(2): 2 is a float (comptime_float), field is i32; use an integer", comptime equalsText(2.0, i32).?);
    try expect("validator: Dto.field_rules.x: equals(10): 10 is a float (f64), field is u64; use an integer", comptime equalsText(@as(f64, 10), u64).?);
    try expect("validator: Dto.field_rules.x: equals(\"5\"): \"5\" is a string, field is i32; use an integer", comptime equalsText("5", i32).?);
    try expect("validator: Dto.field_rules.x: not_equals(\"5\"): \"5\" is a string, field is i32; use an integer", comptime notEqualsText("5", i32).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is u8; use an integer", comptime equalsText(true, u8).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is u8; use an integer", comptime equalsText(.admin, u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(.admin): .admin is an enum tag, field is u8; use an integer", comptime notEqualsText(.admin, u8).?);
    inline for (.{ u8, i8, u64, i64, u128, i128, usize }) |T| {
        try std.testing.expectEqual(null, comptime equalsText(std.math.minInt(T), T));
        try std.testing.expectEqual(null, comptime equalsText(std.math.maxInt(T), T));
        try std.testing.expectEqual(null, comptime notEqualsText(std.math.minInt(T), T));
        try std.testing.expectEqual(null, comptime notEqualsText(std.math.maxInt(T), T));
    }
    try std.testing.expectEqual(null, comptime equalsText(@as(u64, 7), i8));
}

test "on a float field the parameter is a number that stays finite and non-zero in it, and an integer it holds exactly" {
    const expect = std.testing.expectEqualStrings;
    try expect(
        "validator: Dto.field_rules.x: equals(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime equalsText(9007199254740993, f64).?,
    );
    try expect(
        "validator: Dto.field_rules.x: not_equals(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime notEqualsText(9007199254740993, f64).?,
    );
    try expect("validator: Dto.field_rules.x: equals(1e300): 1e300 is outside the finite range of f32; the rule would never pass", comptime equalsText(1e300, f32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1e300): 1e300 is outside the finite range of f32; the rule would always pass", comptime notEqualsText(1e300, f32).?);
    try expect("validator: Dto.field_rules.x: equals(65520): 65520 is outside the finite range of f16; the rule would never pass", comptime equalsText(65520, f16).?);
    try expect("validator: Dto.field_rules.x: equals(1e-50): 1e-50 rounds to 0 in f32", comptime equalsText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1e-50): 1e-50 rounds to 0 in f32", comptime notEqualsText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is f64; use a number", comptime equalsText(true, f64).?);
    try expect("validator: Dto.field_rules.x: not_equals(true): true is a bool, field is f64; use a number", comptime notEqualsText(true, f64).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is f32; use a number", comptime equalsText(.admin, f32).?);
    try expect("validator: Dto.field_rules.x: equals(\"1\"): \"1\" is a string, field is f16; use a number", comptime equalsText("1", f16).?);
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try std.testing.expectEqual(null, comptime equalsText(0.5, F));
        try std.testing.expectEqual(null, comptime equalsText(-0.0, F));
        try std.testing.expectEqual(null, comptime notEqualsText(2, F));
        try std.testing.expectEqual(null, comptime equalsText(0.1, F));
    }
    try std.testing.expectEqual(null, comptime equalsText(@as(f64, 0.1), f32));
    try std.testing.expectEqual(null, comptime equalsText(9007199254740993, f80));
}

test "on a bool field the parameter of equals and notEquals is true or false; on a string field, a string" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(1): 1 is an integer, field is bool; use true or false", comptime equalsText(1, bool).?);
    try expect("validator: Dto.field_rules.x: not_equals(1): 1 is an integer, field is bool; use true or false", comptime notEqualsText(1, bool).?);
    try expect("validator: Dto.field_rules.x: equals(\"true\"): \"true\" is a string, field is bool; use true or false", comptime equalsText("true", bool).?);
    try expect("validator: Dto.field_rules.x: equals(.yes): .yes is an enum tag, field is bool; use true or false", comptime equalsText(.yes, bool).?);
    try expect("validator: Dto.field_rules.x: equals(0.5): 0.5 is a float (comptime_float), field is bool; use true or false", comptime equalsText(0.5, bool).?);
    try expect("validator: Dto.field_rules.x: equals(5): 5 is an integer, field is []const u8; use a string", comptime equalsText(5, []const u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(5): 5 is an integer, field is []const u8; use a string", comptime notEqualsText(5, []const u8).?);
    try expect("validator: Dto.field_rules.x: equals(0.5): 0.5 is a float (comptime_float), field is [:0]const u8; use a string", comptime equalsText(0.5, [:0]const u8).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is []u8; use a string", comptime equalsText(true, []u8).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is [:0]u8; use a string", comptime equalsText(.admin, [:0]u8).?);
    try std.testing.expectEqual(null, comptime equalsText(true, bool));
    try std.testing.expectEqual(null, comptime notEqualsText(false, bool));
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8 }) |S| {
        try std.testing.expectEqual(null, comptime equalsText("a", S));
        try std.testing.expectEqual(null, comptime notEqualsText(@as([]const u8, "root"), S));
    }
}

test "on an enum field the parameter of equals and notEquals is a tag of that enum" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(\"admin\"): \"admin\" is a string, field is common.Role; use a tag such as .admin", comptime equalsText("admin", Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(\"admin\"): \"admin\" is a string, field is common.Role; use a tag such as .admin", comptime notEqualsText("admin", Role).?);
    try expect("validator: Dto.field_rules.x: equals(5): 5 is an integer, field is common.Open; use a tag such as .a", comptime equalsText(5, Open).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is common.Sparse; use a tag such as .low", comptime equalsText(true, Sparse).?);
    try expect("validator: Dto.field_rules.x: equals(.root): common.Role has no tag root; tags: admin, user, guest", comptime equalsText(.root, Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(.root): common.Role has no tag root; tags: admin, user, guest", comptime notEqualsText(.root, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.red): .red is a tag of common.Color, the field is common.Role", comptime equalsText(Color.red, Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(.red): .red is a tag of common.Color, the field is common.Role", comptime notEqualsText(Color.red, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is a tag of common.Color, the field is common.Role", comptime equalsText(Color.admin, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.only): common.Only has a single tag; the rule would always pass", comptime equalsText(.only, Only).?);
    try expect("validator: Dto.field_rules.x: not_equals(.only): common.Only has a single tag; the rule would never pass", comptime notEqualsText(.only, Only).?);
    // An enum without named tags has no tag to suggest or to list.
    try expect("validator: Dto.field_rules.x: equals(\"a\"): \"a\" is a string, field is common.NoTags", comptime equalsText("a", NoTags).?);
    try expect("validator: Dto.field_rules.x: equals(.a): common.NoTags has no tag a", comptime equalsText(.a, NoTags).?);
    try std.testing.expectEqual(null, comptime equalsText(.admin, Role));
    try std.testing.expectEqual(null, comptime notEqualsText(Role.guest, Role));
    try std.testing.expectEqual(null, comptime equalsText(.b, Open));
    // A non-exhaustive single-tag enum also holds unnamed values.
    try std.testing.expectEqual(null, comptime equalsText(.only, OpenOne));
    try std.testing.expectEqual(null, comptime notEqualsText(.only, OpenOne));
    try std.testing.expectEqual(null, comptime equalsText(.high, Sparse));
}

test "equals and notEquals on a field that is not a number, a bool, an enum or a string name the field type" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const expects = " expects a number, a bool, an enum or a string, field is ";
    try expect(head ++ "equals" ++ expects ++ "[]const u32; use v.each(v.equals(5))", comptime equalsText(5, []const u32).?);
    try expect(head ++ "not_equals" ++ expects ++ "[]const u32; use v.each(v.notEquals(5))", comptime notEqualsText(5, []const u32).?);
    try expect(head ++ "equals" ++ expects ++ "[4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime equalsText("abcd", [4]u8).?);
    try expect(head ++ "not_equals" ++ expects ++ "[4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime notEqualsText("abcd", [4]u8).?);
    try expect(head ++ "equals" ++ expects ++ "common.Item", comptime equalsText(5, Item).?);
    try expect(head ++ "not_equals" ++ expects ++ "common.Item", comptime notEqualsText(5, Item).?);
    // The each hint follows the kind of the parameter.
    try expect(head ++ "equals" ++ expects ++ "[]const []const u8; use v.each(v.equals(\"a\"))", comptime equalsText("a", []const []const u8).?);
    try expect(head ++ "equals" ++ expects ++ "[2]common.Role; use v.each(v.equals(.admin))", comptime equalsText(.admin, [2]Role).?);
    try expect(head ++ "equals" ++ expects ++ "[]const ?bool; use v.each(v.equals(true))", comptime equalsText(true, []const ?bool).?);
    try expect(head ++ "equals" ++ expects ++ "[4]u8; use v.each(v.equals(5))", comptime equalsText(5, [4]u8).?);
    try expect(head ++ "equals" ++ expects ++ "[]const []const u8", comptime equalsText(5, []const []const u8).?);
    try expect(head ++ "equals" ++ expects ++ "*const u8", comptime equalsText(5, *const u8).?);
    try expect(head ++ "equals" ++ expects ++ "[]volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime equalsText("a", []volatile u8).?);
}

test "an uncalled equals or notEquals gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals must be called, e.g. v.equals(true)", comptime uncalledText("equals", @TypeOf(equals)));
    try expect("validator: Dto.field_rules.x: notEquals must be called, e.g. v.notEquals(0)", comptime uncalledText("notEquals", @TypeOf(notEquals)));
}

test "equals compares integers and bools exactly, floats in the field type after the finite precondition, tags by name and strings by bytes" {
    try expectOutcome(.pass, equals(5), @as(u8, 5));
    try expectOutcome(.fail, equals(5), @as(u8, 6));
    try expectOutcome(.pass, equals(std.math.maxInt(u128)), @as(u128, std.math.maxInt(u128)));
    try expectOutcome(.pass, equals(std.math.minInt(i128)), @as(i128, std.math.minInt(i128)));
    try expectOutcome(.fail, equals(std.math.minInt(i128)), @as(i128, std.math.maxInt(i128)));
    try expectOutcome(.pass, equals(@as(u8, 7)), @as(i64, 7));
    try expectOutcome(.pass, equals(9007199254740993), @as(u64, 9007199254740993));
    try expectOutcome(.fail, equals(9007199254740993), @as(u64, 9007199254740992));
    try expectOutcome(.pass, equals(0), @as(f64, -0.0));
    try expectOutcome(.pass, equals(-0.0), @as(f16, 0.0));
    try expectOutcome(.pass, equals(0.1), @as(f32, 0.1));
    try expectOutcome(.fail, equals(0.1), std.math.nextAfter(f32, 0.1, 1));
    try expectOutcome(.precondition, equals(0.5), std.math.nan(f32));
    try expectOutcome(.precondition, equals(0.5), -std.math.inf(f128));
    try expectOutcome(.pass, equals(true), true);
    try expectOutcome(.fail, equals(true), false);
    try expectOutcome(.pass, equals(.b), Open.b);
    try expectOutcome(.fail, equals(.b), @as(Open, @fromBackingInt(200)));
    try expectOutcome(.pass, equals(Role.guest), Role.guest);
    try expectOutcome(.pass, equals("abc"), @as([]const u8, "abc"));
    try expectOutcome(.fail, equals("abc"), @as([]const u8, "ABC"));
    try expectOutcome(.fail, equals("abc"), @as([:0]const u8, "abcd"));
}

test "notEquals passes what equals fails; NaN and infinities are the precondition, not a pass" {
    try expectOutcome(.fail, notEquals(5), @as(i8, 5));
    try expectOutcome(.pass, notEquals(5), @as(i8, -5));
    try expectOutcome(.fail, notEquals(0), @as(f16, -0.0));
    try expectOutcome(.pass, notEquals(0), std.math.floatTrueMin(f64));
    try expectOutcome(.precondition, notEquals(0), std.math.nan(f64));
    try expectOutcome(.precondition, notEquals(0), std.math.inf(f64));
    try expectOutcome(.pass, notEquals(.a), @as(Open, @fromBackingInt(200)));
    try expectOutcome(.fail, notEquals(.a), Open.a);
    try expectOutcome(.pass, notEquals("root"), @as([]const u8, ""));
    try expectOutcome(.fail, notEquals("root"), @as([]const u8, "root"));
    try expectOutcome(.fail, notEquals(false), false);
}

test "empty has its documented code and message and no precondition" {
    try std.testing.expectEqualStrings("validation.empty", empty.code);
    try std.testing.expectEqualStrings("must be empty", empty.message);
    try std.testing.expectEqual(core.Kind.empty, empty.kind);
    try std.testing.expectEqual(null, empty.args);
    try std.testing.expectEqual(0, empty.params.len);
    try std.testing.expectEqual(null, empty.precondition);
}

test "empty counts the bytes of a string without decoding them and the items of a slice, null items included" {
    try expectOutcome(.pass, empty, @as([]const u8, ""));
    try expectOutcome(.fail, empty, @as([]const u8, " "));
    try expectOutcome(.fail, empty, @as([]const u8, "\x00"));
    try expectOutcome(.fail, empty, @as([]const u8, "\xff"));
    try expectOutcome(.fail, empty, @as([]const u8, "\u{200b}"));
    try expectOutcome(.pass, empty, @as([:0]const u8, ""));
    try expectOutcome(.pass, empty, @as([]const u32, &.{}));
    try expectOutcome(.fail, empty, @as([]const u32, &.{0}));
    try expectOutcome(.fail, empty, @as([]const ?u32, &.{null}));
}

test "empty and notEmpty on a fixed-size array or a type without a length are errors" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: empty on [3]u32 is always false: the length of an array is fixed", comptime lengthText(empty, [3]u32).?);
    try expect("validator: Dto.field_rules.x: empty on [0]u32 is always true: the length of an array is fixed", comptime lengthText(empty, [0]u32).?);
    try expect(
        "validator: Dto.field_rules.x: empty on [4]u8 is always false: the length of an array is fixed; [N]u8 is an array of numbers, not a string: use []const u8",
        comptime lengthText(empty, [4]u8).?,
    );
    try expect("validator: Dto.field_rules.x: empty expects a string or a slice, field is u32", comptime lengthText(empty, u32).?);
    try expect("validator: Dto.field_rules.x: not_empty on [3]u32 is always true: the length of an array is fixed", comptime lengthText(notEmpty, [3]u32).?);
    try expect("validator: Dto.field_rules.x: not_empty expects a string or a slice, field is bool", comptime lengthText(notEmpty, bool).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []const u32, []u32, []const ?u32, []const []const u8 }) |T| {
        try std.testing.expectEqual(null, comptime lengthText(empty, T));
        try std.testing.expectEqual(null, comptime lengthText(notEmpty, T));
    }
}
