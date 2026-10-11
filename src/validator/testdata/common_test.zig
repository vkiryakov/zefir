//! `v.notEmpty` on every field type it accepts: each string kind, optional
//! strings, strings as list items, and lists of every item kind.
const v = @import("validator");
const h = @import("vtest");

const code = "validation.not_empty";
const message = "must not be empty";

const Role = enum { admin, user };

test "notEmpty has the catalog code and default message" {
    try h.expectRule(v.notEmpty, code, message);
}

test "notEmpty counts the bytes of every string kind without decoding them" {
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectFail(S, v.notEmpty, "", code, message);
        try h.expectPass(S, v.notEmpty, "a");
        try h.expectPass(S, v.notEmpty, " "); // whitespace-only is not empty
        try h.expectPass(S, v.notEmpty, "\x00");
        try h.expectPass(S, v.notEmpty, "\xff"); // invalid UTF-8 is still one byte
    }
    var no_bytes: [0]u8 = .{};
    var one_byte = [_]u8{'x'};
    try h.expectFail([]u8, v.notEmpty, &no_bytes, code, message);
    try h.expectPass([]u8, v.notEmpty, &one_byte);
    var no_bytes_z = [_:0]u8{};
    var one_byte_z = [_:0]u8{'x'};
    try h.expectFail([:0]u8, v.notEmpty, &no_bytes_z, code, message);
    try h.expectPass([:0]u8, v.notEmpty, &one_byte_z);
}

test "notEmpty on ?[]const u8 and ??[]const u8: null skips the rule, the empty string is a present value" {
    try h.expectPass(?[]const u8, v.notEmpty, null);
    try h.expectFail(?[]const u8, v.notEmpty, "", code, message);
    try h.expectPass(?[]const u8, v.notEmpty, "a");
    try h.expectPass(??[]const u8, v.notEmpty, null);
    try h.expectPass(??[]const u8, v.notEmpty, @as(?[]const u8, null));
    try h.expectFail(??[]const u8, v.notEmpty, @as(?[]const u8, ""), code, message);
    try h.expectPass(??[]const u8, v.notEmpty, @as(?[]const u8, "a"));
}

test "notEmpty inside each: slices and arrays of strings, null items skipped with their index kept" {
    const Dto = struct {
        names: []const []const u8 = &.{},
        pair: [2][]const u8 = .{ "a", "b" },
        maybe: []const ?[]const u8 = &.{},
        pub const field_rules = .{
            .names = v.each(v.notEmpty),
            .pair = v.each(v.notEmpty),
            .maybe = v.each(v.notEmpty),
        };
    };
    try h.expectValid(&Dto{ .names = &.{ "a", " " }, .maybe = &.{ null, "b" } });
    try h.expectAt(&Dto{ .names = &.{ "a", "" } }, code, message, "names[1]");
    try h.expectAt(&Dto{ .pair = .{ "", "b" } }, code, message, "pair[0]");
    try h.expectAt(&Dto{ .maybe = &.{ null, null, "" } }, code, message, "maybe[2]");
    try h.expectAll(&Dto{ .names = &.{ "", "a", "" }, .pair = .{ "a", "" }, .maybe = &.{ "", null } }, &.{
        .{ .code = code, .field = "names[0]" },
        .{ .code = code, .field = "names[2]" },
        .{ .code = code, .field = "pair[1]" },
        .{ .code = code, .field = "maybe[0]" },
    });
}

test "notEmpty counts the items of a list, null items included" {
    try h.expectFail([]const u32, v.notEmpty, &.{}, code, message);
    try h.expectPass([]const u32, v.notEmpty, &.{0});
    var no_items: [0]u32 = .{};
    var two_items = [_]u32{ 1, 2 };
    try h.expectFail([]u32, v.notEmpty, &no_items, code, message);
    try h.expectPass([]u32, v.notEmpty, &two_items);
    try h.expectFail([]const ?u32, v.notEmpty, &.{}, code, message);
    try h.expectPass([]const ?u32, v.notEmpty, &.{null});
    try h.expectPass([]const []const u8, v.notEmpty, &.{""}); // one item; the item's own rules judge ""
    try h.expectPass([]const Role, v.notEmpty, &.{.user});
    try h.expectFail([]const bool, v.notEmpty, &.{}, code, message);
    try h.expectPass(?[]const u32, v.notEmpty, null);
    try h.expectFail(?[]const u32, v.notEmpty, &.{}, code, message);
}

test "notEmpty on a list runs before the rules of its items" {
    const Dto = struct {
        tags: []const []const u8,
        pub const field_rules = .{ .tags = .{ v.notEmpty, v.each(v.notEmpty) } };
    };
    try h.expectAt(&Dto{ .tags = &.{} }, code, message, "tags");
    try h.expectAt(&Dto{ .tags = &.{ "a", "" } }, code, message, "tags[1]");
    try h.expectValid(&Dto{ .tags = &.{"a"} });
}
