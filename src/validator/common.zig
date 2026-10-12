//! Common rules: `notEmpty`.
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

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

/// The field-type check of the length rules: a string or a slice that is not
/// a string. On a fixed-size array the rule's verdict never changes, so it is
/// a compile error, with the hint that `[N]u8` is not a string.
fn lengthFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = (a.len == 0) == (rule.kind == .empty);
            core.ruleError(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++
                ": the length of an array is fixed" ++ (if (a.child == u8) "; " ++ core.hints.u8_array else ""));
        },
        else => {},
    }
    if (core.isString(T) or core.isListSlice(T)) return;
    core.typeError(rule, T, where, "a string or a slice", struct {
        fn accepts(comptime F: type) bool {
            return core.isString(F) or core.isListSlice(F);
        }
    }.accepts, null);
}

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
