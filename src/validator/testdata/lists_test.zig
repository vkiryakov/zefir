//! `v.each` on every list type it accepts: slices of any constness, arrays
//! (`[N]u8` included), optional lists, optional items, nested lists, and one
//! rule or a tuple of rules per item.
const v = @import("validator");
const h = @import("vtest");

const positive_code = "validation.positive";
const positive_message = "must be greater than 0";
const not_empty_code = "validation.not_empty";
const not_empty_message = "must not be empty";

fn isLower(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

const lower = v.custom("tags.lowercase", "must be lowercase", isLower);

test "each has no code and no message of its own" {
    try h.expectRule(v.each(v.positive), "", "");
    try h.expectRule(v.each(.{ v.notEmpty, lower }), "", "");
}

test "each on []const T and []T checks every item by index" {
    const Ids = h.One([]const u32, v.each(v.positive));
    try h.expectValid(&Ids{ .x = &.{} });
    try h.expectValid(&Ids{ .x = &.{ 1, 2 } });
    try h.expectAt(&Ids{ .x = &.{ 1, 0, 2 } }, positive_code, positive_message, "x[1]");
    const Mutable = h.One([]u32, v.each(v.positive));
    var items = [_]u32{ 3, 0 };
    try h.expectAt(&Mutable{ .x = &items }, positive_code, positive_message, "x[1]");
}

test "each on arrays: [N]T, [0]T and [N]u8, which is an array of numbers" {
    const Three = h.One([3]i32, v.each(v.positive));
    try h.expectValid(&Three{ .x = .{ 1, 2, 3 } });
    try h.expectAt(&Three{ .x = .{ 1, 2, -3 } }, positive_code, positive_message, "x[2]");
    const None = h.One([0]u32, v.each(v.positive));
    try h.expectValid(&None{ .x = .{} });
    const Bytes = h.One([4]u8, v.each(v.positive));
    try h.expectValid(&Bytes{ .x = .{ 1, 2, 3, 4 } });
    try h.expectAt(&Bytes{ .x = .{ 1, 0, 3, 4 } }, positive_code, positive_message, "x[1]");
}

test "each skips null items and keeps their index; a null list skips everything" {
    const Maybe = h.One([]const ?u32, v.each(v.positive));
    try h.expectValid(&Maybe{ .x = &.{ null, 1, null } });
    try h.expectAt(&Maybe{ .x = &.{ null, null, 0 } }, positive_code, positive_message, "x[2]");
    const Optional = h.One(?[]const u32, v.each(v.positive));
    try h.expectValid(&Optional{ .x = null });
    try h.expectAt(&Optional{ .x = &.{ 1, 0 } }, positive_code, positive_message, "x[1]");
}

test "each(each(r)) applies r to every item of nested slices and arrays" {
    const Nested = h.One([]const []const u32, v.each(v.each(v.positive)));
    try h.expectValid(&Nested{ .x = &.{ &.{}, &.{ 1, 2 } } });
    try h.expectAt(&Nested{ .x = &.{ &.{1}, &.{ 2, 0 } } }, positive_code, positive_message, "x[1][1]");
    const Mutable = h.One([][]u32, v.each(v.each(v.positive)));
    var row0 = [_]u32{1};
    var row1 = [_]u32{ 0, 1 };
    var rows = [_][]u32{ &row0, &row1 };
    try h.expectAt(&Mutable{ .x = &rows }, positive_code, positive_message, "x[1][0]");
    const Grid = h.One([2][3]u8, v.each(v.each(v.positive)));
    try h.expectAt(&Grid{ .x = .{ .{ 1, 1, 1 }, .{ 1, 1, 0 } } }, positive_code, positive_message, "x[1][2]");
}

test "each with a tuple runs the item rules left to right; the first failure is the item's only violation" {
    const Tags = h.One([]const []const u8, v.each(.{ v.notEmpty, lower }));
    try h.expectValid(&Tags{ .x = &.{ "a", "b" } });
    try h.expectAt(&Tags{ .x = &.{ "a", "" } }, not_empty_code, not_empty_message, "x[1]");
    try h.expectAt(&Tags{ .x = &.{ "a", "B" } }, "tags.lowercase", "must be lowercase", "x[1]");
    try h.expectAll(&Tags{ .x = &.{ "", "B", "c", "" } }, &.{
        .{ .code = not_empty_code, .field = "x[0]" },
        .{ .code = "tags.lowercase", .field = "x[1]" },
        .{ .code = not_empty_code, .field = "x[3]" },
    });
}

test "each runs only after the list's own rules passed" {
    const Tags = h.One([]const []const u8, .{ v.notEmpty, v.each(v.notEmpty) });
    try h.expectAt(&Tags{ .x = &.{} }, not_empty_code, not_empty_message, "x");
    try h.expectAt(&Tags{ .x = &.{""} }, not_empty_code, not_empty_message, "x[0]");
    try h.expectValid(&Tags{ .x = &.{"a"} });
}
