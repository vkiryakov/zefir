//! `assertRules` accepts every type that `check` accepts: roots of every
//! kind, and fields the walker does not descend into, as long as nothing
//! below them declares `field_rules` or `validateSelf`.
const std = @import("std");
const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Plain = struct { n: u32 };
const Kind = enum { a, b };
const Choice = union(enum) { plain: Plain, none: void };

/// Types that reach themselves, with no rules below them.
const Node = struct { n: u32, next: ?*const Node = null };
const Tree = struct { kids: []const Tree = &.{} };

fn noop() void {}

/// Every field before `items` is a type the walker does not descend into;
/// none of them reaches rules, so none of them is an error.
const Opaque = struct {
    choice: Choice = .{ .none = {} },
    kind: Kind = .a,
    one: *const Plain,
    many: [*]const Plain,
    c_pointer: [*c]const Plain = null,
    maybe: ?*const Plain = null,
    array_pointer: *const [2]Plain,
    pair: struct { u32, Plain } = .{ 0, .{ .n = 0 } },
    result: anyerror!Plain = .{ .n = 0 },
    lanes: @Vector(2, u32) = .{ 0, 0 },
    callback: *const fn () void = &noop,
    volatile_bytes: []volatile u8,
    allowzero_bytes: []allowzero const u8,
    volatile_plains: []volatile Plain,
    list: ?*const Node = null,
    tree: Tree = .{},
    items: []const Item,
    pub const field_rules = .{ .items = v.notEmpty };
};

test "assertRules accepts fields the walker does not descend into when nothing below them declares rules" {
    comptime v.assertRules(Opaque);
    var plains = [_]Plain{ .{ .n = 1 }, .{ .n = 2 } };
    var bytes = [_]u8{ 1, 2 };
    const value: Opaque = .{
        .one = &plains[0],
        .many = &plains,
        .array_pointer = &plains,
        .volatile_bytes = &bytes,
        .allowzero_bytes = &bytes,
        .volatile_plains = &plains,
        .items = &.{ .{ .name = "a" }, .{ .name = "" } },
    };
    var path_buf: [64]u8 = undefined;
    const violation = v.check(&value, &path_buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("validation.not_empty", violation.code);
    try std.testing.expectEqualStrings("items[1].name", violation.field orelse return error.TestUnexpectedResult);
}

test "assertRules accepts every root that check accepts" {
    comptime {
        v.assertRules(Item);
        v.assertRules([]const Item);
        v.assertRules([2]Item);
        v.assertRules([]const []const Item);
        v.assertRules([]const ?Item);
        v.assertRules(?Item);
        v.assertRules(u32);
        v.assertRules([]const u8);
        v.assertRules(Kind);
        v.assertRules(Choice);
        v.assertRules([]const u32);
        v.assertRules(*const Plain);
        v.assertRules(void);
    }
}
