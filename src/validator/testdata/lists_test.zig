//! `v.each` on every list type it accepts: slices of any constness, arrays
//! (`[N]u8` included), optional lists, optional items, nested lists, and one
//! rule or a tuple of rules per item. `v.minItems` and `v.maxItems` on every
//! kind of slice, optional slices, and inner lists through `each`.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");

const positive_code = "validation.positive";
const positive_message = "must be greater than 0";
const not_empty_code = "validation.not_empty";
const not_empty_message = "must not be empty";
const min_items_code = "validation.min_items";
const max_items_code = "validation.max_items";

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

const Point = struct { x: i32 };

test "minItems and maxItems have their documented codes and messages, one item in the singular" {
    try h.expectRule(v.minItems(1), min_items_code, "must have at least 1 item");
    try h.expectRule(v.minItems(2), min_items_code, "must have at least 2 items");
    try h.expectRule(v.maxItems(1), max_items_code, "must have at most 1 item");
    try h.expectRule(v.maxItems(100), max_items_code, "must have at most 100 items");
}

test "minItems counts the items of every kind of slice: const or not, with a sentinel, aligned, of strings and of structs" {
    const two = "must have at least 2 items";
    try h.expectFail([]const u32, v.minItems(2), &.{1}, min_items_code, two);
    try h.expectPass([]const u32, v.minItems(2), &.{ 1, 2 });
    try h.expectFail([]const u32, v.minItems(1), &.{}, min_items_code, "must have at least 1 item");
    try h.expectFail([:0]const u32, v.minItems(2), &[_:0]u32{1}, min_items_code, two);
    try h.expectPass([:0]const u32, v.minItems(2), &[_:0]u32{ 1, 2 });
    var one = [_]u32{1};
    var pair = [_]u32{ 1, 2 };
    try h.expectFail([]u32, v.minItems(2), &one, min_items_code, two);
    try h.expectPass([]u32, v.minItems(2), &pair);
    var one_z = [_:0]u32{1};
    try h.expectFail([:0]u32, v.minItems(2), &one_z, min_items_code, two);
    const aligned align(8) = [_]u32{ 1, 2 };
    try h.expectPass([]align(8) const u32, v.minItems(2), &aligned);
    try h.expectFail([]const []const u8, v.minItems(2), &.{"a"}, min_items_code, two);
    try h.expectPass([]const []const u8, v.minItems(2), &.{ "", "" });
    try h.expectFail([]const Point, v.minItems(2), &.{.{ .x = 1 }}, min_items_code, two);
    // Items are counted, never checked: a NaN item counts like any other.
    try h.expectPass([]const f64, v.minItems(1), &.{std.math.nan(f64)});
}

test "maxItems counts the items of every kind of slice" {
    const two = "must have at most 2 items";
    try h.expectPass([]const u32, v.maxItems(2), &.{});
    try h.expectPass([]const u32, v.maxItems(2), &.{ 1, 2 });
    try h.expectFail([]const u32, v.maxItems(2), &.{ 1, 2, 3 }, max_items_code, two);
    try h.expectFail([]const u32, v.maxItems(1), &.{ 1, 2 }, max_items_code, "must have at most 1 item");
    try h.expectFail([:0]const u32, v.maxItems(2), &[_:0]u32{ 1, 2, 3 }, max_items_code, two);
    var three = [_]u32{ 1, 2, 3 };
    try h.expectFail([]u32, v.maxItems(2), &three, max_items_code, two);
    try h.expectFail([]const []const u8, v.maxItems(2), &.{ "a", "b", "c" }, max_items_code, two);
    try h.expectPass([]const Point, v.maxItems(2), &.{ .{ .x = 1 }, .{ .x = 2 } });
}

test "minItems and maxItems count null items" {
    try h.expectPass([]const ?u32, v.minItems(2), &.{ null, null });
    try h.expectFail([]const ?u32, v.minItems(2), &.{null}, min_items_code, "must have at least 2 items");
    try h.expectFail([]const ?u32, v.maxItems(2), &.{ null, 1, null }, max_items_code, "must have at most 2 items");
    try h.expectFail([]const ?[]const u8, v.maxItems(1), &.{ null, null }, max_items_code, "must have at most 1 item");
}

test "minItems and maxItems on optional slices: null skips the rule, an empty slice is a present value" {
    const none: []const u32 = &.{};
    const three: []const u32 = &.{ 1, 2, 3 };
    try h.expectPass(?[]const u32, v.minItems(1), null);
    try h.expectFail(?[]const u32, v.minItems(1), none, min_items_code, "must have at least 1 item");
    try h.expectPass(??[]const u32, v.minItems(1), null);
    try h.expectPass(??[]const u32, v.minItems(1), @as(?[]const u32, null));
    try h.expectFail(??[]const u32, v.minItems(1), @as(?[]const u32, none), min_items_code, "must have at least 1 item");
    try h.expectPass(?[]const u32, v.maxItems(2), null);
    try h.expectFail(?[]const u32, v.maxItems(2), three, max_items_code, "must have at most 2 items");
}

test "each(minItems(n)) and each(maxItems(n)) count the items of every inner list" {
    const Rows = h.One([]const []const u32, v.each(v.minItems(1)));
    try h.expectValid(&Rows{ .x = &.{ &.{1}, &.{ 1, 2 } } });
    try h.expectAt(&Rows{ .x = &.{ &.{1}, &.{} } }, min_items_code, "must have at least 1 item", "x[1]");
    const Grid = h.One([][]u32, v.each(v.maxItems(2)));
    var row0 = [_]u32{ 1, 2 };
    var row1 = [_]u32{ 1, 2, 3 };
    var rows = [_][]u32{ &row0, &row1 };
    try h.expectAt(&Grid{ .x = &rows }, max_items_code, "must have at most 2 items", "x[1]");
    const Pair = h.One([2][]const u32, v.each(v.maxItems(1)));
    try h.expectValid(&Pair{ .x = .{ &.{}, &.{1} } });
    try h.expectAt(&Pair{ .x = .{ &.{ 1, 2 }, &.{} } }, max_items_code, "must have at most 1 item", "x[0]");
    // A null inner list is skipped and keeps its index.
    const Maybe = h.One([]const ?[]const u32, v.each(v.minItems(2)));
    try h.expectValid(&Maybe{ .x = &.{ null, &.{ 1, 2 } } });
    try h.expectAt(&Maybe{ .x = &.{ null, &.{1} } }, min_items_code, "must have at least 2 items", "x[1]");
    // Two levels down: each(each(minItems(n))).
    const Deep = h.One([]const []const []const u32, v.each(v.each(v.minItems(1))));
    try h.expectAt(&Deep{ .x = &.{ &.{&.{1}}, &.{ &.{1}, &.{} } } }, min_items_code, "must have at least 1 item", "x[1][1]");
}

test "minItems and maxItems run in tuple order before each; notEmpty and minItems(1) overlap with their own codes" {
    const Tags = h.One([]const []const u8, .{ v.minItems(1), v.maxItems(2), v.each(v.notEmpty) });
    try h.expectAt(&Tags{ .x = &.{} }, min_items_code, "must have at least 1 item", "x");
    try h.expectAt(&Tags{ .x = &.{ "a", "b", "c" } }, max_items_code, "must have at most 2 items", "x");
    try h.expectAt(&Tags{ .x = &.{ "a", "" } }, not_empty_code, not_empty_message, "x[1]");
    try h.expectValid(&Tags{ .x = &.{"a"} });
    const Exact = h.One([]const u32, .{ v.minItems(3), v.maxItems(3) });
    try h.expectValid(&Exact{ .x = &.{ 1, 2, 3 } });
    try h.expectAt(&Exact{ .x = &.{ 1, 2 } }, min_items_code, "must have at least 3 items", "x");
    const Both = h.One([]const u32, .{ v.notEmpty, v.minItems(1) });
    try h.expectAt(&Both{ .x = &.{} }, not_empty_code, not_empty_message, "x");
    const Reversed = h.One([]const u32, .{ v.minItems(1), v.notEmpty });
    try h.expectAt(&Reversed{ .x = &.{} }, min_items_code, "must have at least 1 item", "x");
}
