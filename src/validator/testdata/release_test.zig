//! Built with ReleaseSafe whatever -Doptimize says. A malformed validateSelf
//! result is a programmer error that fails closed outside Debug: it is
//! reported as validation.invalid / "is invalid" at the struct's path (a
//! Debug build panics instead: see panic/). A list longer than
//! max_unique_items, which the declaration checks keep from uniqueItems and
//! uniqueBy, fails them rather than overrunning their stack buffers.
const std = @import("std");
const builtin = @import("builtin");
const v = @import("validator");
const testing = std.testing;

const BadField = struct {
    n: u32,
    pub fn validateSelf(_: *const BadField) ?v.Violation {
        return .{ .code = "t.bad", .message = "bad", .field = "nope" };
    }
};
const ComptimeField = struct {
    comptime version: u32 = 1,
    n: u32,
    pub fn validateSelf(_: *const ComptimeField) ?v.Violation {
        return .{ .code = "t.bad", .message = "bad", .field = "version" };
    }
};
const ReservedCode = struct {
    n: u32,
    pub fn validateSelf(_: *const ReservedCode) ?v.Violation {
        return .{ .code = "validation.fake", .message = "fake" };
    }
};
const OneSegment = struct {
    n: u32,
    pub fn validateSelf(_: *const OneSegment) ?v.Violation {
        return .{ .code = "fake", .message = "fake", .field = "n" };
    }
};
const EmptyMessage = struct {
    n: u32,
    pub fn validateSelf(_: *const EmptyMessage) ?v.Violation {
        return .{ .code = "t.empty", .message = "", .field = "n" };
    }
};
const long_message: [v.max_message_bytes + 1]u8 = @splat('m');
const LongMessage = struct {
    n: u32,
    pub fn validateSelf(_: *const LongMessage) ?v.Violation {
        return .{ .code = "t.long", .message = &long_message };
    }
};
const BadUtf8 = struct {
    n: u32,
    pub fn validateSelf(_: *const BadUtf8) ?v.Violation {
        return .{ .code = "t.utf8", .message = "\xff" };
    }
};
const Holder = struct {
    a: []const BadField = &.{},
    b: ?ReservedCode = null,
};
const Fine = struct {
    n: u32,
    pub fn validateSelf(_: *const Fine) ?v.Violation {
        return .{ .code = "t.fine", .message = "fine", .field = "n" };
    }
};
const Wrapper = struct { fine: Fine };
const NearName = struct {
    name: []const u8 = "n",
    returned: []const u8,
    pub fn validateSelf(self: *const NearName) ?v.Violation {
        return .{ .code = "t.near", .message = "near", .field = self.returned };
    }
};

/// `check` and `checkAll` both report validation.invalid first, at `field`.
fn expectInvalid(value: anytype, field: ?[]const u8) !void {
    var buf: [64]u8 = undefined;
    const got = v.check(value, &buf) orelse return error.NoViolation;
    try testing.expectEqualStrings("validation.invalid", got.code);
    try testing.expectEqualStrings("is invalid", got.message);
    const report = try v.checkAll(testing.allocator, value);
    defer report.deinit();
    try testing.expectEqualStrings("validation.invalid", report.violations[0].code);
    try testing.expectEqualStrings("is invalid", report.violations[0].message);
    if (field) |f| {
        try testing.expectEqualStrings(f, got.field orelse return error.FieldIsNull);
        try testing.expectEqualStrings(f, report.violations[0].field orelse return error.FieldIsNull);
    } else {
        try testing.expectEqual(null, got.field);
        try testing.expectEqual(null, report.violations[0].field);
    }
}

test "this file is built with ReleaseSafe" {
    try testing.expectEqual(.safe, builtin.mode);
}

test "a malformed validateSelf result is reported as validation.invalid at the struct's path" {
    try expectInvalid(&BadField{ .n = 1 }, null); // not a field of the struct
    try expectInvalid(&ComptimeField{ .n = 1 }, null); // a comptime field
    try expectInvalid(&ReservedCode{ .n = 1 }, null); // a reserved code
    try expectInvalid(&OneSegment{ .n = 1 }, null); // a code with one segment
    try expectInvalid(&EmptyMessage{ .n = 1 }, null); // an empty message
    try expectInvalid(&LongMessage{ .n = 1 }, null); // a message over 512 bytes
    try expectInvalid(&BadUtf8{ .n = 1 }, null); // invalid UTF-8
    try expectInvalid(&Holder{ .a = &.{ .{ .n = 1 }, .{ .n = 2 } } }, "a[0]");
    try expectInvalid(&Holder{ .b = .{ .n = 1 } }, "b");
}

test "a hand-built field must be a field name exactly: a prefix, a longer name or another case is invalid" {
    try expectInvalid(&NearName{ .returned = "na" }, null);
    try expectInvalid(&NearName{ .returned = "names" }, null);
    try expectInvalid(&NearName{ .returned = "Name" }, null);
    var buf: [64]u8 = undefined;
    const exact = v.check(&NearName{ .returned = "name" }, &buf) orelse return error.NoViolation;
    try testing.expectEqualStrings("t.near", exact.code);
    try testing.expectEqualStrings("name", exact.field orelse return error.FieldIsNull);
}

test "a well-formed hand-built result is reported as returned" {
    var buf: [64]u8 = undefined;
    const got = v.check(&Wrapper{ .fine = .{ .n = 0 } }, &buf) orelse return error.NoViolation;
    try testing.expectEqualStrings("t.fine", got.code);
    try testing.expectEqualStrings("fine", got.message);
    try testing.expectEqualStrings("fine.n", got.field.?);
}

const OpenMode = enum(u16) { read, _ };
const Keyed = struct { id: u32 };

/// One more value than max_unique_items, all different.
const over_cap = v.max_unique_items + 1;

fn overCapInts() [over_cap]u64 {
    var out: [over_cap]u64 = undefined;
    for (&out, 0..) |*slot, i| slot.* = i;
    return out;
}

fn overCapStrings() [over_cap][]const u8 {
    @setEvalBranchQuota(10_000_000);
    var out: [over_cap][]const u8 = undefined;
    for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("item-{d}", .{i});
    const final = out;
    return final;
}

test "a list longer than max_unique_items fails uniqueItems and uniqueBy without a panic" {
    const ints = overCapInts();
    const int_items: []const u64 = &ints;
    try testing.expect(v.uniqueItems.eval(&int_items) == .fail);
    const strings = comptime overCapStrings();
    const string_items: []const []const u8 = &strings;
    try testing.expect(v.uniqueItems.eval(&string_items) == .fail);
    var modes: [over_cap]OpenMode = undefined;
    for (&modes, 0..) |*slot, i| slot.* = @fromBackingInt(@intCast(i));
    const mode_items: []const OpenMode = &modes;
    try testing.expect(v.uniqueItems.eval(&mode_items) == .fail);
    var keyed: [over_cap]Keyed = undefined;
    for (&keyed, 0..) |*slot, i| slot.* = .{ .id = @intCast(i) };
    const keyed_items: []const Keyed = &keyed;
    try testing.expect(v.uniqueBy(.id).eval(&keyed_items) == .fail);
    // At the cap, the same values pass.
    const at_cap: []const u64 = ints[0..v.max_unique_items];
    try testing.expect(v.uniqueItems.eval(&at_cap) == .pass);
    const strings_at_cap: []const []const u8 = strings[0..v.max_unique_items];
    try testing.expect(v.uniqueItems.eval(&strings_at_cap) == .pass);
}
