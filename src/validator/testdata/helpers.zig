//! Helpers for the validator tests in this folder: the module "vtest", which
//! build.zig adds to every file of `cases.test_files`. Every helper that runs
//! a value runs both `check` and `checkAll` and fails when the first
//! violation of `checkAll` differs from `check`'s result. A helper prints its
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
/// `x` itself; `checkAll` must agree (none, or exactly that one). The
/// returned `field` is a static "x".
pub fn run(comptime T: type, comptime rules: anytype, value: T) !?v.Violation {
    const Dto = One(T, rules);
    const dto: Dto = .{ .x = value };
    var buf: [256]u8 = undefined;
    const first = v.check(&dto, &buf);
    const report = try v.checkAll(testing.allocator, &dto);
    defer report.deinit();
    const got = first orelse {
        try testing.expectEqual(0, report.violations.len);
        return null;
    };
    try testing.expectEqual(1, report.violations.len);
    try expectSame(report.violations[0], got);
    try expectField("x", got.field);
    // Code and message are static strings: safe to return after `buf` and
    // the report are gone.
    return .{ .code = got.code, .message = got.message, .field = "x" };
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

/// Neither `check` nor `checkAll` finds a violation in `value.*`.
pub fn expectValid(value: anytype) !void {
    try expectAll(value, &.{});
}

/// A violation `expectAll` expects: its code and field.
pub const Expected = struct { code: []const u8, field: ?[]const u8 };

/// `checkAll` returns exactly these violations in this order, without
/// truncation, and its first one equals `check`'s result (code, message and
/// field, with a 4096-byte path_buf).
pub fn expectAll(value: anytype, expected: []const Expected) !void {
    const report = try v.checkAll(testing.allocator, value);
    defer report.deinit();
    errdefer dump(report.violations);
    try testing.expectEqual(expected.len, report.violations.len);
    for (expected, report.violations) |e, got| {
        try testing.expectEqualStrings(e.code, got.code);
        try expectField(e.field, got.field);
    }
    try testing.expect(!report.truncated);
    var buf: [4096]u8 = undefined;
    const first = v.check(value, &buf);
    if (report.violations.len == 0) {
        if (first) |got| {
            std.debug.print("checkAll found nothing, check found {s} at {?s}\n", .{ got.code, got.field });
            return error.CheckDisagrees;
        }
    } else {
        try expectSame(report.violations[0], first orelse return error.CheckFoundNothing);
    }
}

/// Prints a report's violations (on a failed expectation).
pub fn dump(violations: []const v.Violation) void {
    std.debug.print("\n  got {d} violation(s):\n", .{violations.len});
    for (violations) |violation| std.debug.print("    {s}: {s} ({s})\n", .{ violation.field orelse "<null>", violation.code, violation.message });
}

/// `check` returns exactly this violation (`message` null skips the message,
/// `field` null expects a null field), and it is the first one of `checkAll`.
pub fn expectAt(value: anytype, code: []const u8, message: ?[]const u8, field: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const got = v.check(value, &buf) orelse {
        std.debug.print("expected {s} at {?s}, got no violation\n", .{ code, field });
        return error.NoViolation;
    };
    try testing.expectEqualStrings(code, got.code);
    if (message) |m| try testing.expectEqualStrings(m, got.message);
    try expectField(field, got.field);
    const report = try v.checkAll(testing.allocator, value);
    defer report.deinit();
    if (report.violations.len == 0) return error.CheckAllFoundNothing;
    try expectSame(got, report.violations[0]);
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
