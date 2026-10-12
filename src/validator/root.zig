//! zefir-validator — validation rules declared on your structs: a struct
//! lists the rules of its fields in `pub const field_rules`, and `v.check`
//! returns the first violation of a value without allocating.
//!
//! ```zig
//! const SignUp = struct {
//!     name: []const u8,
//!     age: u8,
//!     tags: []const []const u8 = &.{},
//!
//!     pub const field_rules = .{
//!         .name = v.notEmpty,
//!         .age = v.positive,
//!         .tags = v.each(v.notEmpty),
//!     };
//! };
//!
//! var path_buf: [256]u8 = undefined;
//! if (v.check(&request, &path_buf)) |violation| {
//!     // violation.code, violation.message, violation.field ("tags[1]")
//!     std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
//! }
//! ```
//!
//! Rules are checked against their fields' types at compile time, when
//! `v.check`, `v.checkAll` or `v.assertRules` is instantiated for a type; a
//! mistake is a compile error that starts with "validator: ". Since Zig
//! compiles only code that is used, a DTO package calls
//! `comptime v.assertRules(T)` in a test. `v.checkAll` collects every
//! violation into a `Report`, `validateSelf` with `v.fail` checks across
//! fields, and `v.custom` turns a predicate of your own into a rule. The guide
//! is src/validator/examples/README.md.

const std = @import("std");
const core = @import("core.zig");
const walk = @import("walk.zig");
const common = @import("common.zig");
const numbers = @import("numbers.zig");
const formats = @import("formats.zig");
const lists = @import("lists.zig");
const custom_rules = @import("custom.zig");

pub const Violation = core.Violation;
pub const Rule = core.Rule;
pub const Report = walk.Report;

pub const max_code_bytes = core.max_code_bytes;
pub const max_message_bytes = core.max_message_bytes;
pub const max_report_violations = core.max_report_violations;

pub const check = walk.check;
pub const checkAll = walk.checkAll;
pub const assertRules = walk.assertRules;
pub const fail = walk.fail;

pub const equals = common.equals;
pub const notEquals = common.notEquals;
pub const oneOf = common.oneOf;
pub const noneOf = common.noneOf;
pub const empty = common.empty;
pub const notEmpty = common.notEmpty;
pub const min = numbers.min;
pub const max = numbers.max;
pub const range = numbers.range;
pub const positive = numbers.positive;
pub const nonNegative = numbers.nonNegative;
pub const negative = numbers.negative;
pub const nonPositive = numbers.nonPositive;
pub const divisibleBy = numbers.divisibleBy;
pub const finite = numbers.finite;
pub const numberString = formats.numberString;
pub const decimal = formats.decimal;
pub const booleanString = formats.booleanString;
pub const hexadecimal = formats.hexadecimal;
pub const octal = formats.octal;
pub const port = formats.port;
pub const latitude = formats.latitude;
pub const longitude = formats.longitude;
pub const latLong = formats.latLong;
pub const ip = formats.ip;
pub const ipv4 = formats.ipv4;
pub const ipv6 = formats.ipv6;
pub const macAddress = formats.macAddress;
pub const DecimalOptions = formats.DecimalOptions;
pub const MacAddressOptions = formats.MacAddressOptions;
pub const isNumberString = formats.isNumberString;
pub const isDecimal = formats.isDecimal;
pub const isBooleanString = formats.isBooleanString;
pub const isHexadecimal = formats.isHexadecimal;
pub const isOctal = formats.isOctal;
pub const isPort = formats.isPort;
pub const isLatitude = formats.isLatitude;
pub const isLongitude = formats.isLongitude;
pub const isLatLong = formats.isLatLong;
pub const isIp = formats.isIp;
pub const isIpv4 = formats.isIpv4;
pub const isIpv6 = formats.isIpv6;
pub const isMacAddress = formats.isMacAddress;
pub const minItems = lists.minItems;
pub const maxItems = lists.maxItems;
pub const each = lists.each;
pub const custom = custom_rules.custom;

test {
    _ = core;
    _ = walk;
    _ = common;
    _ = numbers;
    _ = formats;
    _ = lists;
    _ = custom_rules;
}

test "limits have their documented values" {
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
