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
const encodings = @import("encodings.zig");
const dates = @import("dates.zig");
const lists = @import("lists.zig");
const custom_rules = @import("custom.zig");

pub const Violation = core.Violation;
pub const Rule = core.Rule;
pub const Report = walk.Report;

pub const max_code_bytes = core.max_code_bytes;
pub const max_message_bytes = core.max_message_bytes;
pub const max_report_violations = core.max_report_violations;
pub const max_json_depth = core.max_json_depth;

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
pub const json = encodings.json;
pub const isJson = encodings.isJson;
pub const jwt = encodings.jwt;
pub const isJwt = encodings.isJwt;
pub const base32 = encodings.base32;
pub const isBase32 = encodings.isBase32;
pub const base58 = encodings.base58;
pub const isBase58 = encodings.isBase58;
pub const base64 = encodings.base64;
pub const isBase64 = encodings.isBase64;
pub const base64Url = encodings.base64Url;
pub const isBase64Url = encodings.isBase64Url;
pub const dataUri = encodings.dataUri;
pub const isDataUri = encodings.isDataUri;
pub const magnetUri = encodings.magnetUri;
pub const isMagnetUri = encodings.isMagnetUri;
pub const mimeType = encodings.mimeType;
pub const isMimeType = encodings.isMimeType;
pub const locale = encodings.locale;
pub const isLocale = encodings.isLocale;
pub const semVer = encodings.semVer;
pub const isSemVer = encodings.isSemVer;
pub const hexColor = encodings.hexColor;
pub const isHexColor = encodings.isHexColor;
pub const rgbColor = encodings.rgbColor;
pub const isRgbColor = encodings.isRgbColor;
pub const hslColor = encodings.hslColor;
pub const isHslColor = encodings.isHslColor;
pub const date = dates.date;
pub const isDate = dates.isDate;
pub const rfc3339 = dates.rfc3339;
pub const isRfc3339 = dates.isRfc3339;
pub const iso8601 = dates.iso8601;
pub const isIso8601 = dates.isIso8601;
pub const minDate = dates.minDate;
pub const maxDate = dates.maxDate;
pub const militaryTime = dates.militaryTime;
pub const isMilitaryTime = dates.isMilitaryTime;
pub const minItems = lists.minItems;
pub const maxItems = lists.maxItems;
pub const each = lists.each;
pub const custom = custom_rules.custom;

test {
    _ = core;
    _ = walk;
    _ = common;
    _ = numbers;
    _ = encodings;
    _ = dates;
    _ = lists;
    _ = custom_rules;
}

test "limits have their documented values" {
    try std.testing.expectEqual(128, max_code_bytes);
    try std.testing.expectEqual(512, max_message_bytes);
    try std.testing.expectEqual(100, max_report_violations);
    try std.testing.expectEqual(64, max_json_depth);
    // comptime_int, so a limit sizes an array or compares with any integer type.
    try std.testing.expect(@TypeOf(max_code_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_message_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_report_violations) == comptime_int);
    try std.testing.expect(@TypeOf(max_json_depth) == comptime_int);
}

test "a violation has no field unless one is given" {
    const at_root: Violation = .{ .code = "users.name_taken", .message = "is taken" };
    try std.testing.expectEqual(null, at_root.field);
    const at_field: Violation = .{ .code = "users.name_taken", .message = "is taken", .field = "name" };
    try std.testing.expectEqualStrings("name", at_field.field.?);
}
