//! Paths: the text of `Violation.field`, how `check` writes it into
//! `path_buf`, and the paths and the cap of `checkAll`.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Address = struct {
    city: []const u8,
    pub const field_rules = .{ .city = v.notEmpty };
};

const User = struct {
    email: []const u8,
    pub const field_rules = .{ .email = v.notEmpty };
};

const Customer = struct {
    name: []const u8 = "n",
    address: Address = .{ .city = "c" },
    billing: ?Address = null,
    shipping: ??Address = null,
    items: []const Item = &.{},
    maybe_items: []const ?Item = &.{},
    matrix: [2][2]u32 = .{ .{ 1, 1 }, .{ 1, 1 } },
    pub const field_rules = .{ .name = v.notEmpty, .matrix = v.each(v.each(v.positive)) };
};

test "a path joins field names with dots and writes each index in brackets" {
    try h.expectAt(&Customer{ .name = "" }, "validation.not_empty", "must not be empty", "name");
    try h.expectAt(&Customer{ .address = .{ .city = "" } }, "validation.not_empty", null, "address.city");
    try h.expectAt(&Customer{ .items = &.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "" } } }, "validation.not_empty", null, "items[2].name");
    try h.expectAt(&Customer{ .matrix = .{ .{ 1, 1 }, .{ 0, 1 } } }, "validation.positive", null, "matrix[1][0]");
    const many: [11]Item = @splat(.{ .name = "a" });
    var items = many;
    items[10].name = "";
    try h.expectAt(&Customer{ .items = &items }, "validation.not_empty", null, "items[10].name");
    const users: []const User = &.{ .{ .email = "a@b" }, .{ .email = "" } };
    try h.expectAt(&users, "validation.not_empty", null, "[1].email");
    const rows: []const []const User = &.{ &.{}, &.{ .{ .email = "x" }, .{ .email = "" } } };
    try h.expectAt(&rows, "validation.not_empty", null, "[1][1].email");
}

test "an optional adds no path segment" {
    try h.expectAt(&Customer{ .billing = .{ .city = "" } }, "validation.not_empty", null, "billing.city");
    try h.expectAt(&Customer{ .shipping = @as(?Address, .{ .city = "" }) }, "validation.not_empty", null, "shipping.city");
    try h.expectAt(&Customer{ .maybe_items = &.{ null, .{ .name = "" } } }, "validation.not_empty", null, "maybe_items[1].name");
    const maybe: ?User = .{ .email = "" };
    try h.expectAt(&maybe, "validation.not_empty", null, "email");
}

const Cyrillic = struct {
    @"имя": []const u8,
    pub const field_rules = .{ .@"имя" = v.notEmpty };
};

test "non-ASCII field names appear in paths verbatim" {
    try h.expectAll(&Cyrillic{ .@"имя" = "" }, &.{.{ .code = "validation.not_empty", .field = "имя" }});
}

/// `check` with every `path_buf` length from 0 to two bytes past the path:
/// the path is returned (and points into `path_buf`) exactly when it fits;
/// the code and the message are always complete.
fn expectBoundary(value: anytype, path: []const u8, code: []const u8, message: []const u8) !void {
    var big: [512]u8 = undefined;
    for (0..path.len + 3) |size| {
        const got = v.check(value, big[0..size]) orelse return error.NoViolation;
        try testing.expectEqualStrings(code, got.code);
        try testing.expectEqualStrings(message, got.message);
        if (size >= path.len) {
            try h.expectField(path, got.field);
            try testing.expectEqual(@as([*]const u8, &big), got.field.?.ptr);
        } else {
            try h.expectField(null, got.field);
        }
    }
}

test "check: a path of exactly path_buf.len bytes fits; one byte more gives field = null with the full code and message" {
    try expectBoundary(&Customer{ .address = .{ .city = "" } }, "address.city", "validation.not_empty", "must not be empty");
    const many: [11]Item = @splat(.{ .name = "a" });
    var items = many;
    items[10].name = "";
    try expectBoundary(&Customer{ .items = &items }, "items[10].name", "validation.not_empty", "must not be empty");
    const users: []const User = &.{ .{ .email = "a" }, .{ .email = "" } };
    try expectBoundary(&users, "[1].email", "validation.not_empty", "must not be empty");
    try expectBoundary(&Customer{ .matrix = .{ .{ 1, 1 }, .{ 1, 0 } } }, "matrix[1][1]", "validation.positive", "must be greater than 0");
}

const Siblings = struct {
    a_long_field_name_that_overflows_the_buffer: Address = .{ .city = "ok" },
    nested: struct { deeper_and_longer_still: Address = .{ .city = "ok" } } = .{},
    short: Address,
};

const LongThenShort = struct {
    a_rather_long_field_name_that_overflows: Address = .{ .city = "ok" },
    x: u32,
    pub const field_rules = .{ .x = v.positive };
};

test "check: an overflow inside an earlier sibling's subtree does not corrupt a later, shorter path" {
    const value: Siblings = .{ .short = .{ .city = "" } };
    var buf: [10]u8 = undefined; // "short.city" is 10 bytes; the earlier paths are longer
    try h.expectSame(.{ .code = "validation.not_empty", .message = "must not be empty", .field = "short.city" }, v.check(&value, &buf) orelse return error.NoViolation);
    var one: [1]u8 = undefined;
    try h.expectSame(.{ .code = "validation.positive", .message = "must be greater than 0", .field = "x" }, v.check(&LongThenShort{ .x = 0 }, &one) orelse return error.NoViolation);
}

test "check: an empty path_buf always gives field = null" {
    var empty: [0]u8 = .{};
    try h.expectSame(.{ .code = "validation.not_empty", .message = "must not be empty", .field = null }, v.check(&Customer{ .name = "" }, &empty) orelse return error.NoViolation);
    try h.expectSame(.{ .code = "validation.positive", .message = "must be greater than 0", .field = null }, v.check(&LongThenShort{ .x = 0 }, &empty) orelse return error.NoViolation);
    try testing.expectEqual(null, v.check(&Customer{}, &empty));
}

/// `depth` nested levels with 45-byte field names: a path of about 4.6 KB
/// at depth 100.
fn Level(comptime depth: usize) type {
    if (depth == 0) return Address;
    return struct { a_long_field_name_to_make_the_path_long_00000: Level(depth - 1) };
}

fn deepValue(comptime depth: usize) Level(depth) {
    if (depth == 0) return .{ .city = "" };
    return .{ .a_long_field_name_to_make_the_path_long_00000 = deepValue(depth - 1) };
}

test "checkAll: paths are copied into the report and have no length limit" {
    const depth = 100;
    const value = deepValue(depth);
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(1, report.violations.len);
    const path = report.violations[0].field.?;
    try testing.expectEqual(depth * "a_long_field_name_to_make_the_path_long_00000.".len + "city".len, path.len);
    try testing.expect(std.mem.endsWith(u8, path, "_00000.city"));
    var small: [4096]u8 = undefined;
    try testing.expectEqual(null, (v.check(&value, &small) orelse return error.NoViolation).field);
    var large: [8192]u8 = undefined;
    try testing.expectEqualStrings(path, (v.check(&value, &large) orelse return error.NoViolation).field.?);
}

const Many = struct { items: []const Item };

test "checkAll keeps the first max_report_violations violations in walk order and says when it dropped more" {
    var items: [250]Item = @splat(.{ .name = "" });
    var report = try v.checkAll(testing.allocator, &Many{ .items = &items });
    try testing.expectEqual(v.max_report_violations, report.violations.len);
    try testing.expect(report.truncated);
    try testing.expectEqualStrings("items[0].name", report.violations[0].field.?);
    try testing.expectEqualStrings("items[99].name", report.violations[99].field.?);
    report.deinit();
    // exactly the cap: nothing was dropped
    report = try v.checkAll(testing.allocator, &Many{ .items = items[0..v.max_report_violations] });
    try testing.expectEqual(v.max_report_violations, report.violations.len);
    try testing.expect(!report.truncated);
    report.deinit();
    // one more than the cap
    report = try v.checkAll(testing.allocator, &Many{ .items = items[0 .. v.max_report_violations + 1] });
    try testing.expectEqual(v.max_report_violations, report.violations.len);
    try testing.expect(report.truncated);
    try testing.expectEqualStrings("items[99].name", report.violations[99].field.?);
    report.deinit();
    // a valid value: an empty report, still to be freed
    items[0].name = "x";
    report = try v.checkAll(testing.allocator, &Many{ .items = items[0..1] });
    try testing.expectEqual(0, report.violations.len);
    try testing.expect(!report.truncated);
    report.deinit();
}

const WithAddress = struct { address: Address };

test "the first violation of checkAll equals check: code and message always, field when the path fits path_buf" {
    const value: WithAddress = .{ .address = .{ .city = "" } };
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    var small: [8]u8 = undefined; // "address.city" needs 12 bytes
    const first = v.check(&value, &small) orelse return error.NoViolation;
    try testing.expectEqualStrings(report.violations[0].code, first.code);
    try testing.expectEqualStrings(report.violations[0].message, first.message);
    try testing.expectEqualStrings("address.city", report.violations[0].field.?);
    try testing.expectEqual(null, first.field);
    var exact: [12]u8 = undefined;
    try h.expectSame(report.violations[0], v.check(&value, &exact) orelse return error.NoViolation);
}
