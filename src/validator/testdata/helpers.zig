//! Helpers for the validator tests in this folder: the module "vtest", which
//! build.zig adds to every file of `cases.test_files`. A helper prints its
//! diagnosis with std.debug.print only when its expectation fails.
const std = @import("std");
const v = @import("validator");
const testing = std.testing;

/// A DTO with one field `x` of type `T` and the given rules.
pub fn One(comptime T: type, comptime rules: anytype) type {
    return struct {
        x: T,
        pub const field_rules = .{ .x = rules };
    };
}

/// `check` on `.{ .x = value }`: null, or the violation, which must be at
/// `x` itself. The returned `field` is a static "x".
pub fn run(comptime T: type, comptime rules: anytype, value: T) !?v.Violation {
    const Dto = One(T, rules);
    const dto: Dto = .{ .x = value };
    var buf: [256]u8 = undefined;
    const first = v.check(&dto, &buf) orelse return null;
    try expectField("x", first.field);
    // Code and message are static strings: safe to return after `buf` is gone.
    return .{ .code = first.code, .message = first.message, .field = "x" };
}

/// `.{ .x = value }` fails with exactly this code and message at `x`.
pub fn expectFail(comptime T: type, comptime rules: anytype, value: T, code: []const u8, message: []const u8) !void {
    const got = (try run(T, rules, value)) orelse {
        std.debug.print("expected {s} ({s}), got no violation\n", .{ code, message });
        return error.NoViolation;
    };
    testing.expectEqualStrings(code, got.code) catch |err| {
        std.debug.print("message was: {s}\n", .{got.message});
        return err;
    };
    try testing.expectEqualStrings(message, got.message);
}

/// `.{ .x = value }` passes.
pub fn expectPass(comptime T: type, comptime rules: anytype, value: T) !void {
    if (try run(T, rules, value)) |got| {
        std.debug.print("expected no violation, got {s}: {s}\n", .{ got.code, got.message });
        return error.UnexpectedViolation;
    }
}

/// `check` finds no violation in `value.*`.
pub fn expectValid(value: anytype) !void {
    var buf: [256]u8 = undefined;
    if (v.check(value, &buf)) |got| {
        std.debug.print("expected no violation, got {s} at {?s}: {s}\n", .{ got.code, got.field, got.message });
        return error.UnexpectedViolation;
    }
}

/// `check` returns exactly this violation: `message` null skips the message,
/// `field` null expects a null field.
pub fn expectAt(value: anytype, code: []const u8, message: ?[]const u8, field: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const got = v.check(value, &buf) orelse {
        std.debug.print("expected {s} at {?s}, got no violation\n", .{ code, field });
        return error.NoViolation;
    };
    try testing.expectEqualStrings(code, got.code);
    if (message) |m| try testing.expectEqualStrings(m, got.message);
    try expectField(field, got.field);
}

/// A rule's code and message.
pub fn expectRule(comptime rule: v.Rule, code: []const u8, message: []const u8) !void {
    try testing.expectEqualStrings(code, rule.code);
    try testing.expectEqualStrings(message, rule.message);
}

/// Two violations have the same code, message and field.
pub fn expectSame(expected: v.Violation, actual: v.Violation) !void {
    try testing.expectEqualStrings(expected.code, actual.code);
    try testing.expectEqualStrings(expected.message, actual.message);
    try expectField(expected.field, actual.field);
}

/// A field (path) is `expected`; null means no path.
pub fn expectField(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |e| {
        const a = actual orelse {
            std.debug.print("expected field '{s}', got null\n", .{e});
            return error.FieldIsNull;
        };
        try testing.expectEqualStrings(e, a);
    } else if (actual) |a| {
        std.debug.print("expected field null, got '{s}'\n", .{a});
        return error.FieldIsNotNull;
    }
}
