//! zefir-validator: declarative validation of DTOs. Rules are comptime
//! values declared next to the fields they check: a rule that does not fit
//! its field type is a compile error, and a value that breaks a rule is
//! reported as a `Violation` with a stable code, a message and the path of
//! the field.

const std = @import("std");
const core = @import("core.zig");
const walk = @import("walk.zig");
const common = @import("common.zig");
const numbers = @import("numbers.zig");
const lists = @import("lists.zig");
const custom_rules = @import("custom.zig");

pub const Violation = core.Violation;
pub const Rule = core.Rule;

pub const max_code_bytes = core.max_code_bytes;
pub const max_message_bytes = core.max_message_bytes;
pub const max_report_violations = core.max_report_violations;

pub const check = walk.check;

pub const notEmpty = common.notEmpty;
pub const positive = numbers.positive;
pub const each = lists.each;
pub const custom = custom_rules.custom;

test {
    _ = core;
    _ = walk;
    _ = common;
    _ = numbers;
    _ = lists;
    _ = custom_rules;
}

test "limits match the catalog" {
    try std.testing.expectEqual(128, max_code_bytes);
    try std.testing.expectEqual(512, max_message_bytes);
    try std.testing.expectEqual(100, max_report_violations);
    // comptime_int, so a limit sizes an array or compares with any integer type.
    try std.testing.expect(@TypeOf(max_code_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_message_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_report_violations) == comptime_int);
}

test "a violation has no field unless one is given" {
    const at_root: Violation = .{ .code = "users.name_taken", .message = "is taken" };
    try std.testing.expectEqual(null, at_root.field);
    const at_field: Violation = .{ .code = "users.name_taken", .message = "is taken", .field = "name" };
    try std.testing.expectEqualStrings("name", at_field.field.?);
}
