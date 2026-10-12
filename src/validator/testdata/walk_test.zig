//! The walk: the order of fields, items and rules, `each`, optionals, the
//! types the walker descends into, and the roots `check` accepts. Tests that
//! count predicate calls call `v.check` directly, so each count is one walk.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Inner = struct {
    n: u32,
    pub const field_rules = .{ .n = v.positive };
};

fn notAbc(s: []const u8) bool {
    return !std.mem.eql(u8, s, "abc");
}

// ------------------------------------------------------------------ order

const Pair = struct {
    p: u32,
    q: u32,
    pub const field_rules = .{ .q = v.positive, .p = v.positive }; // keys in another order than the fields
};

const Ordered = struct {
    b: u32, // declared before a
    a: u32,
    pair: Pair,
    items: []const Pair,
    y: u32,
    pub const field_rules = .{ .y = v.positive, .a = v.positive, .b = v.positive };
};

test "fields are walked depth first in declaration order, not in field_rules order; items by index" {
    var value: Ordered = .{ .b = 0, .a = 0, .pair = .{ .p = 0, .q = 0 }, .items = &.{ .{ .p = 1, .q = 0 }, .{ .p = 0, .q = 1 } }, .y = 0 };
    try h.expectAt(&value, "validation.positive", "must be greater than 0", "b");
    value.b = 1;
    try h.expectAt(&value, "validation.positive", null, "a");
    value.a = 1;
    try h.expectAt(&value, "validation.positive", null, "pair.p");
    value.pair.p = 1;
    try h.expectAt(&value, "validation.positive", null, "pair.q");
    value.pair.q = 1;
    try h.expectAt(&value, "validation.positive", null, "items[0].q");
    value.items = &.{ .{ .p = 1, .q = 1 }, .{ .p = 0, .q = 1 } };
    try h.expectAt(&value, "validation.positive", null, "items[1].p");
    value.items = &.{ .{ .p = 1, .q = 1 }, .{ .p = 1, .q = 1 } };
    try h.expectAt(&value, "validation.positive", null, "y");
    value.y = 1;
    try h.expectValid(&value);
}

var third_calls: usize = 0;

fn notAb(s: []const u8) bool {
    return !std.mem.eql(u8, s, "ab");
}

fn notNo(s: []const u8) bool {
    third_calls += 1;
    return !std.mem.eql(u8, s, "no");
}

const Named = struct {
    name: []const u8,
    pub const field_rules = .{ .name = .{ v.notEmpty, v.custom("t.second", "second rule failed", notAb), v.custom("t.third", "third rule failed", notNo) } };
};

test "rules run left to right; the first failure is the value's only violation and later rules do not run" {
    var buf: [16]u8 = undefined;
    third_calls = 0;
    try h.expectSame(.{ .code = "validation.not_empty", .message = "must not be empty", .field = "name" }, v.check(&Named{ .name = "" }, &buf) orelse return error.NoViolation);
    try h.expectSame(.{ .code = "t.second", .message = "second rule failed", .field = "name" }, v.check(&Named{ .name = "ab" }, &buf) orelse return error.NoViolation);
    try testing.expectEqual(0, third_calls);
    try h.expectSame(.{ .code = "t.third", .message = "third rule failed", .field = "name" }, v.check(&Named{ .name = "no" }, &buf) orelse return error.NoViolation);
    try testing.expectEqual(1, third_calls);
    try testing.expectEqual(null, v.check(&Named{ .name = "ok" }, &buf));
    try testing.expectEqual(2, third_calls);
}

fn rejectInner(_: Inner) bool {
    return false;
}

const HasStruct = struct {
    inner: Inner,
    pub const field_rules = .{ .inner = v.custom("t.inner_rejected", "inner rejected", rejectInner) };
};

test "a rule on a struct-typed field runs before anything inside the struct" {
    try h.expectAt(&HasStruct{ .inner = .{ .n = 0 } }, "t.inner_rejected", "inner rejected", "inner");
}

const Address = struct {
    city: []const u8,
    pub const field_rules = .{ .city = v.notEmpty };
};

const Paths = struct {
    address: Address = .{ .city = "c" },
    items: []const Item = &.{},
    matrix: [2][2]u32 = .{ .{ 1, 1 }, .{ 1, 1 } },
    pub const field_rules = .{ .matrix = v.each(v.each(v.positive)) };
};

test "paths join field names with dots and put every index in brackets" {
    try h.expectAt(&Paths{ .address = .{ .city = "" } }, "validation.not_empty", null, "address.city");
    try h.expectAt(&Paths{ .items = &.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "" } } }, "validation.not_empty", null, "items[2].name");
    try h.expectAt(&Paths{ .matrix = .{ .{ 1, 1 }, .{ 0, 1 } } }, "validation.positive", null, "matrix[1][0]");
}

// ------------------------------------------------------------------ each

var entry_rule_calls: usize = 0;
var entry_name_calls: usize = 0;

fn notRejected(entry: *const Entry) bool {
    entry_rule_calls += 1;
    return !std.mem.eql(u8, entry.name, "reject");
}

fn hasName(name: []const u8) bool {
    entry_name_calls += 1;
    return name.len != 0;
}

fn atMostFive(entries: []const Entry) bool {
    return entries.len <= 5;
}

const Entry = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.custom("t.entry_name", "name must not be empty", hasName) };
};

const Entries = struct {
    entries: []const Entry,
    pub const field_rules = .{ .entries = .{ v.custom("t.too_many", "must have at most 5 items", atMostFive), v.each(v.custom("t.rejected", "entry rejected", notRejected)) } };
};

fn resetEntryCalls() void {
    entry_rule_calls = 0;
    entry_name_calls = 0;
}

test "each item is walked once: the rules of each, then the item type's own rules" {
    var buf: [32]u8 = undefined;
    resetEntryCalls();
    try testing.expectEqual(null, v.check(&Entries{ .entries = &.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" } } }, &buf));
    try testing.expectEqual(3, entry_rule_calls);
    try testing.expectEqual(3, entry_name_calls);
}

test "an item whose each rule failed is not descended into; the items before it were" {
    var buf: [32]u8 = undefined;
    resetEntryCalls();
    const got = v.check(&Entries{ .entries = &.{ .{ .name = "a" }, .{ .name = "reject" }, .{ .name = "" } } }, &buf) orelse return error.NoViolation;
    try h.expectSame(.{ .code = "t.rejected", .message = "entry rejected", .field = "entries[1]" }, got);
    try testing.expectEqual(2, entry_rule_calls);
    try testing.expectEqual(1, entry_name_calls); // entries[1].name was never checked
}

test "when a list's own rule fails, none of its items is visited" {
    var buf: [32]u8 = undefined;
    resetEntryCalls();
    const six: [6]Entry = @splat(.{ .name = "" });
    const got = v.check(&Entries{ .entries = &six }, &buf) orelse return error.NoViolation;
    try h.expectSame(.{ .code = "t.too_many", .message = "must have at most 5 items", .field = "entries" }, got);
    try testing.expectEqual(0, entry_rule_calls);
    try testing.expectEqual(0, entry_name_calls);
}

fn atMostOne(tags: []const []const u8) bool {
    return tags.len <= 1;
}

const Tags = struct {
    tags: []const []const u8,
    pub const field_rules = .{ .tags = .{ v.custom("t.at_most_one", "must have at most 1 item", atMostOne), v.each(v.notEmpty) } };
};

test "each comes last: the list's own rules run first, its items only when they passed" {
    try h.expectAt(&Tags{ .tags = &.{ "", "" } }, "t.at_most_one", "must have at most 1 item", "tags");
    try h.expectAt(&Tags{ .tags = &.{""} }, "validation.not_empty", "must not be empty", "tags[0]");
    try h.expectValid(&Tags{ .tags = &.{"a"} });
}

var cell_calls: usize = 0;

fn countCell(_: u32) bool {
    cell_calls += 1;
    return true;
}

const Grid = struct {
    cells: []const []const u32,
    pub const field_rules = .{ .cells = v.each(v.each(v.custom("t.cell", "cell rejected", countCell))) };
};

test "each(each(r)) applies r once to every item of every row" {
    var buf: [32]u8 = undefined;
    cell_calls = 0;
    try testing.expectEqual(null, v.check(&Grid{ .cells = &.{ &.{ 1, 2, 3 }, &.{}, &.{ 4, 5 } } }, &buf));
    try testing.expectEqual(5, cell_calls);
}

const Rows = struct {
    rows: []const []const []const u8,
    pub const field_rules = .{ .rows = v.each(.{ v.notEmpty, v.each(.{ v.notEmpty, v.custom("t.not_abc", "must not be abc", notAbc) }) }) };
};

test "nested each: a row's own rules run before its items; a path has one index per level" {
    try h.expectAt(&Rows{ .rows = &.{ &.{ "a", "" }, &.{}, &.{ "abc", "ok" } } }, "validation.not_empty", null, "rows[0][1]");
    try h.expectAt(&Rows{ .rows = &.{ &.{ "a", "b" }, &.{}, &.{ "abc", "ok" } } }, "validation.not_empty", null, "rows[1]");
    try h.expectAt(&Rows{ .rows = &.{ &.{ "a", "b" }, &.{"c"}, &.{ "abc", "ok" } } }, "t.not_abc", "must not be abc", "rows[2][0]");
    try h.expectValid(&Rows{ .rows = &.{ &.{ "a", "b" }, &.{"c"}, &.{ "ok", "abd" } } });
}

test "each declares item rules: it has no code or message of its own" {
    try h.expectRule(v.each(v.notEmpty), "", "");
    try h.expectRule(v.notEmpty, "validation.not_empty", "must not be empty");
}

// ------------------------------------------------------------------ optionals

var whole_calls: usize = 0;
var list_item_calls: usize = 0;

fn countWhole(_: *const Inner) bool {
    whole_calls += 1;
    return true;
}

fn countListItem(_: *const Inner) bool {
    list_item_calls += 1;
    return true;
}

const Optionals = struct {
    inner: ?Inner = null,
    list: ?[]const Inner = null,
    text: ?[]const u8 = null,
    num: ?u32 = null,
    pub const field_rules = .{
        .inner = v.custom("t.whole", "whole rejected", countWhole),
        .list = .{ v.notEmpty, v.each(v.custom("t.list_item", "item rejected", countListItem)) },
        .text = .{ v.notEmpty, v.custom("t.not_abc", "must not be abc", notAbc) },
        .num = v.positive,
    };
};

test "null skips the field's rules, its each and everything inside it" {
    var buf: [32]u8 = undefined;
    whole_calls = 0;
    list_item_calls = 0;
    try testing.expectEqual(null, v.check(&Optionals{}, &buf));
    try testing.expectEqual(0, whole_calls);
    try testing.expectEqual(0, list_item_calls);
}

test "a value inside an optional is checked as the plain type" {
    try h.expectAt(&Optionals{ .inner = .{ .n = 0 } }, "validation.positive", null, "inner.n");
    try h.expectAt(&Optionals{ .list = &.{} }, "validation.not_empty", null, "list");
    try h.expectAt(&Optionals{ .list = &.{ .{ .n = 1 }, .{ .n = 0 } } }, "validation.positive", null, "list[1].n");
    try h.expectAt(&Optionals{ .text = "" }, "validation.not_empty", null, "text");
    try h.expectAt(&Optionals{ .text = "abc" }, "t.not_abc", null, "text");
    try h.expectAt(&Optionals{ .num = 0 }, "validation.positive", null, "num");
    try h.expectValid(&Optionals{ .inner = .{ .n = 1 }, .list = &.{.{ .n = 1 }}, .text = "x", .num = 1 });
}

const DoubleOptional = struct {
    x: ??i32,
    pub const field_rules = .{ .x = v.positive };
};

test "??T: null at either level skips the rules, which are checked against T" {
    try h.expectValid(&DoubleOptional{ .x = null });
    try h.expectValid(&DoubleOptional{ .x = @as(?i32, null) });
    try h.expectValid(&DoubleOptional{ .x = 5 });
    try h.expectAt(&DoubleOptional{ .x = 0 }, "validation.positive", null, "x");
    try h.expectAt(&DoubleOptional{ .x = @as(?i32, -1) }, "validation.positive", null, "x");
}

const OptionalItems = struct {
    items: []const ?Inner = &.{},
    tags: []const ?[]const u8 = &.{},
    pub const field_rules = .{ .tags = v.each(v.notEmpty) };
};

test "null items are skipped; the other items keep their index" {
    try h.expectAt(&OptionalItems{ .items = &.{ null, .{ .n = 1 }, null, .{ .n = 0 } } }, "validation.positive", null, "items[3].n");
    try h.expectAt(&OptionalItems{ .tags = &.{ null, "a", null, "" } }, "validation.not_empty", null, "tags[3]");
    try h.expectValid(&OptionalItems{ .items = &.{ null, null }, .tags = &.{ null, null } });
}

fn atMostTwo(ids: []const ?u32) bool {
    return ids.len <= 2;
}

const NullCounts = struct {
    ids: []const ?u32,
    name: ?[]const u8 = null,
    pub const field_rules = .{
        .ids = .{ v.notEmpty, v.custom("t.at_most_two", "must have at most 2 items", atMostTwo), v.each(v.positive) },
        .name = v.notEmpty,
    };
};

test "list rules count null items, item rules never see them; notEmpty on ?[]const u8 passes null" {
    try h.expectValid(&NullCounts{ .ids = &.{null} }); // notEmpty passes on [null]
    try h.expectAt(&NullCounts{ .ids = &.{ null, null, null } }, "t.at_most_two", null, "ids");
    try h.expectAt(&NullCounts{ .ids = &.{ null, 0 } }, "validation.positive", null, "ids[1]");
    try h.expectValid(&NullCounts{ .ids = &.{1}, .name = null });
    try h.expectAt(&NullCounts{ .ids = &.{1}, .name = "" }, "validation.not_empty", null, "name");
}

test "\"\" is a present value and is checked; whitespace is not trimmed" {
    try h.expectAt(&Item{ .name = "" }, "validation.not_empty", null, "name");
    try h.expectValid(&Item{ .name = " " });
}

// ------------------------------------------------------------------ types

const Color = enum { red, green, blue };

fn notBlue(c: Color) bool {
    return c != .blue;
}

fn isTrue(b: bool) bool {
    return b;
}

test "leaves: a bool, an integer, a float, an enum and every string kind run their rules" {
    try h.expectFail(bool, v.custom("t.flag", "must be true", isTrue), false, "t.flag", "must be true");
    try h.expectPass(bool, v.custom("t.flag", "must be true", isTrue), true);
    try h.expectFail(i8, v.positive, -1, "validation.positive", "must be greater than 0");
    try h.expectFail(u64, v.positive, 0, "validation.positive", "must be greater than 0");
    try h.expectFail(f32, v.positive, std.math.nan(f32), "validation.finite", "must be a finite number");
    try h.expectFail(f64, v.positive, -0.0, "validation.positive", "must be greater than 0");
    try h.expectPass(f64, v.positive, 1e-300);
    try h.expectFail(Color, v.custom("t.color", "must not be blue", notBlue), .blue, "t.color", "must not be blue");
    try h.expectPass(Color, v.custom("t.color", "must not be blue", notBlue), .red);
    try h.expectFail([]const u8, v.notEmpty, "", "validation.not_empty", "must not be empty");
    try h.expectFail([:0]const u8, v.notEmpty, "", "validation.not_empty", "must not be empty");
    var no_bytes: [0]u8 = .{};
    try h.expectFail([]u8, v.notEmpty, &no_bytes, "validation.not_empty", "must not be empty");
    var abc = "abc".*;
    try h.expectPass([]u8, v.notEmpty, &abc);
    try h.expectPass([:0]u8, v.notEmpty, &abc);
}

const NoRules = struct { inner: Item }; // walked: there are rules below it

fn atMostThree(items: []const ?Item) bool {
    return items.len <= 3;
}

const Walked = struct {
    grid: []const []const Item = &.{},
    maybe_items: ?[]const ?Item = null,
    matrix: [2][3]u32 = .{ .{ 1, 1, 1 }, .{ 1, 1, 1 } },
    item_matrix: [2][2]Item = .{ .{ .{ .name = "a" }, .{ .name = "a" } }, .{ .{ .name = "a" }, .{ .name = "a" } } },
    bytes: [3]u8 = .{ 1, 1, 1 },
    wrapper: NoRules = .{ .inner = .{ .name = "a" } },
    mutable_items: []Item = &.{},
    pub const field_rules = .{
        .maybe_items = v.custom("t.at_most_three", "must have at most 3 items", atMostThree),
        .matrix = v.each(v.each(v.positive)),
        .bytes = v.each(v.positive),
    };
};

test "walked: [][]T, ?[]const ?T, [N][M]T, [N]u8 as numbers, a struct without field_rules, []T" {
    try h.expectValid(&Walked{});
    try h.expectAt(&Walked{ .grid = &.{ &.{.{ .name = "a" }}, &.{ .{ .name = "a" }, .{ .name = "" } } } }, "validation.not_empty", null, "grid[1][1].name");
    try h.expectAt(&Walked{ .maybe_items = &.{ .{ .name = "a" }, null, .{ .name = "" } } }, "validation.not_empty", null, "maybe_items[2].name");
    try h.expectAt(&Walked{ .maybe_items = &.{ null, null, null, null } }, "t.at_most_three", null, "maybe_items");
    try h.expectAt(&Walked{ .matrix = .{ .{ 1, 1, 1 }, .{ 1, 0, 1 } } }, "validation.positive", null, "matrix[1][1]");
    var item_matrix = (Walked{}).item_matrix;
    item_matrix[1][0].name = "";
    try h.expectAt(&Walked{ .item_matrix = item_matrix }, "validation.not_empty", null, "item_matrix[1][0].name");
    try h.expectAt(&Walked{ .bytes = .{ 1, 0, 1 } }, "validation.positive", null, "bytes[1]");
    try h.expectAt(&Walked{ .wrapper = .{ .inner = .{ .name = "" } } }, "validation.not_empty", null, "wrapper.inner.name");
    var mutable = [_]Item{ .{ .name = "m" }, .{ .name = "" } };
    try h.expectAt(&Walked{ .mutable_items = &mutable }, "validation.not_empty", null, "mutable_items[1].name");
}

const Plain = struct { x: u32 };
const PlainUnion = union(enum) { a: u32, b: Plain };

fn noop() void {}

const Ignored = struct {
    u: PlainUnion = .{ .a = 0 },
    p: *const u32,
    op: ?*const Plain = null,
    many: [*]const u8,
    eu: anyerror!u32 = 0,
    vec: @Vector(2, u8) = .{ 0, 0 },
    tuple: struct { u32, Plain } = .{ 0, .{ .x = 0 } },
    func: *const fn () void,
    plain_list: []const Plain = &.{.{ .x = 0 }},
    n: u32,
    pub const field_rules = .{ .n = v.positive };
};

test "unions, pointers, error unions, vectors, tuples and functions without rules are not walked" {
    const zero: u32 = 0;
    try h.expectAt(&Ignored{ .p = &zero, .many = "abc", .func = &noop, .n = 0 }, "validation.positive", null, "n");
}

fn shapeOk(shape: *const PlainUnion) bool {
    return switch (shape.*) {
        .a => |a| a != 0,
        .b => |b| b.x != 0,
    };
}

const RuleOnUnion = struct {
    shape: PlainUnion,
    pub const field_rules = .{ .shape = v.custom("t.shape", "shape must be non-zero", shapeOk) };
};

test "a rule on a union field runs when it fits the union; the walker does not descend into it" {
    try h.expectAt(&RuleOnUnion{ .shape = .{ .b = .{ .x = 0 } } }, "t.shape", "shape must be non-zero", "shape");
    try h.expectValid(&RuleOnUnion{ .shape = .{ .a = 3 } });
}

const Containers = struct {
    list: std.ArrayList(Item) = .empty,
    by_name: std.StringHashMapUnmanaged(Item) = .empty,
};

test "std.ArrayList is walked through its items slice; a map that hides its item type is not walked" {
    const gpa = testing.allocator;
    var value: Containers = .{};
    defer value.list.deinit(gpa);
    defer value.by_name.deinit(gpa);
    try value.list.append(gpa, .{ .name = "a" });
    try value.list.append(gpa, .{ .name = "" });
    try value.by_name.put(gpa, "k", .{ .name = "" });
    try h.expectAt(&value, "validation.not_empty", null, "list.items[1].name");
    value.list.items[1].name = "b";
    try h.expectValid(&value);
}

const Defaults = struct {
    note: []const u8 = "",
    count: u32 = 0,
    pub const field_rules = .{ .note = v.notEmpty, .count = v.positive };
};

test "fields with default values are checked like any other field" {
    try h.expectAt(&Defaults{}, "validation.not_empty", null, "note");
    try h.expectAt(&Defaults{ .note = "n" }, "validation.positive", null, "count");
    try h.expectValid(&Defaults{ .note = "n", .count = 1 });
}

const WithComptime = struct {
    comptime version: u32 = 0,
    comptime item: Item = .{ .name = "" }, // its rule would fail if the walker visited it
    n: u32,
    pub const field_rules = .{ .n = v.positive };
};

test "comptime fields are never walked" {
    try h.expectValid(&WithComptime{ .n = 1 });
    try h.expectAt(&WithComptime{ .n = 0 }, "validation.positive", null, "n");
}

fn notSeven(level: *const u3) bool {
    return level.* != 7;
}

const Bits = packed struct {
    low: u4,
    high: u4,
    pub const field_rules = .{ .high = v.positive };
};

const Flags = packed struct {
    level: u3,
    count: u5,
    bits: Bits,
    enabled: bool,
    pub const field_rules = .{ .count = v.positive, .level = v.custom("t.level", "level must not be 7", notSeven) };
};

const HasFlags = struct {
    flags: Flags,
    list: []const Flags = &.{},
};

test "packed structs are walked: a rule gets a copy of its field, since a packed field has a bit pointer" {
    const ok: Flags = .{ .level = 1, .count = 1, .bits = .{ .low = 0, .high = 1 }, .enabled = true };
    try h.expectValid(&HasFlags{ .flags = ok, .list = &.{ ok, ok } });
    try h.expectAt(&HasFlags{ .flags = .{ .level = 7, .count = 0, .bits = ok.bits, .enabled = true } }, "t.level", "level must not be 7", "flags.level");
    try h.expectAt(&HasFlags{ .flags = .{ .level = 1, .count = 0, .bits = ok.bits, .enabled = true } }, "validation.positive", null, "flags.count");
    try h.expectAt(&HasFlags{ .flags = .{ .level = 1, .count = 1, .bits = .{ .low = 3, .high = 0 }, .enabled = false } }, "validation.positive", null, "flags.bits.high");
    try h.expectAt(&HasFlags{ .flags = ok, .list = &.{ ok, .{ .level = 1, .count = 0, .bits = ok.bits, .enabled = false } } }, "validation.positive", null, "list[1].count");
    try h.expectAt(&Flags{ .level = 2, .count = 0, .bits = ok.bits, .enabled = true }, "validation.positive", null, "count");
}

const UnderAligned = struct {
    n: u32 align(1) = 1,
    items: [2]Item align(1) = .{ .{ .name = "a" }, .{ .name = "a" } },
    pub const field_rules = .{ .n = v.positive };
};

test "a field declared below the alignment of its type is walked through a copy, like a packed field" {
    try h.expectValid(&UnderAligned{});
    try h.expectAt(&UnderAligned{ .n = 0 }, "validation.positive", "must be greater than 0", "n");
    try h.expectAt(&UnderAligned{ .items = .{ .{ .name = "a" }, .{ .name = "" } } }, "validation.not_empty", null, "items[1].name");
}

const Anonymous = struct {
    address: struct {
        city: []const u8,
        pub const field_rules = .{ .city = v.notEmpty };
    },
};

test "a field whose type is an anonymous struct is walked" {
    try h.expectAt(&Anonymous{ .address = .{ .city = "" } }, "validation.not_empty", null, "address.city");
}

const Meta = struct { @"x.y": u32 = 0 }; // no rules below it: never visited

const WithMeta = struct {
    meta: Meta = .{},
    n: u32,
    pub const field_rules = .{ .n = v.positive };
};

test "a struct with no rules below it is never visited, whatever its field names" {
    try h.expectAt(&WithMeta{ .n = 0 }, "validation.positive", null, "n");
}

const ConfyStyle = struct {
    port: u16,
    pub const field_rules = .{ .port = v.positive };
    pub fn validate(self: ConfyStyle) !void {
        if (self.port == 7) return error.Seven;
    }
};

test "a pub fn validate (confy's hook) is left alone" {
    try h.expectAt(&ConfyStyle{ .port = 0 }, "validation.positive", null, "port");
    try h.expectValid(&ConfyStyle{ .port = 7 });
}

const CheckWrapper = struct {
    port: u16,
    pub const field_rules = .{ .port = v.positive };
    pub fn validate(self: *const CheckWrapper, path_buf: []u8) ?v.Violation {
        return v.check(self, path_buf);
    }
};

test "a pub fn validate that is not shaped like validateSelf is left alone" {
    var buf: [64]u8 = undefined;
    const violation = (CheckWrapper{ .port = 0 }).validate(&buf) orelse return error.TestExpectedViolation;
    try std.testing.expectEqualStrings("validation.positive", violation.code);
    try h.expectValid(&CheckWrapper{ .port = 1 });
}

const EmptyRules = struct {
    n: u32,
    pub const field_rules = .{};
};

test "an empty field_rules .{} is allowed and declares no rules" {
    try h.expectValid(&EmptyRules{ .n = 0 });
}

// ------------------------------------------------------------------ in place

/// Holds its own address in `at`, so its rules tell the value from a copy.
const Pinned = struct {
    at: usize = 0,
    pub fn validateSelf(self: *const Pinned) ?v.Violation {
        if (self.at != @intFromPtr(self)) return v.fail(Pinned, null, "t.copied", "was walked through a copy");
        return null;
    }
};

fn pin(pinned: *Pinned) void {
    pinned.at = @intFromPtr(pinned);
}

fn seesItself(pinned: *const Pinned) bool {
    return pinned.at == @intFromPtr(pinned);
}

const PinnedFields = struct {
    one: Pinned = .{},
    maybe: ?Pinned = null,
    list: []const Pinned = &.{},
    array: [2]Pinned = .{ .{}, .{} },
    pub const field_rules = .{
        .one = v.custom("t.copied", "was walked through a copy", seesItself),
        .maybe = v.custom("t.copied", "was walked through a copy", seesItself),
        .list = v.each(v.custom("t.copied", "was walked through a copy", seesItself)),
        .array = v.each(v.custom("t.copied", "was walked through a copy", seesItself)),
    };
};

const UnderAlignedPinned = struct { pinned: Pinned align(1) = .{} };

test "fields, items and optional payloads are walked in place: a fn (*const T) bool predicate and validateSelf get the value itself" {
    var items: [3]Pinned = undefined;
    for (&items) |*item| pin(item);
    var value: PinnedFields = .{ .maybe = .{}, .list = &items };
    pin(&value.one);
    pin(&value.maybe.?);
    for (&value.array) |*item| pin(item);
    try h.expectValid(&value);
    // An under-aligned field is walked through a copy, which the check above would see.
    var copied: UnderAlignedPinned = .{};
    copied.pinned.at = @intFromPtr(&copied.pinned);
    try h.expectAt(&copied, "t.copied", "was walked through a copy", "pinned");
}

// ------------------------------------------------------------------ roots

const User = struct {
    email: []const u8,
    pub const field_rules = .{ .email = v.notEmpty };
};

const Shape = union(enum) { circle: f32, square: f32 };

test "roots: a struct, a slice passed as &slice, an array, nested slices and optionals" {
    try h.expectAt(&User{ .email = "" }, "validation.not_empty", null, "email");
    const users: []const User = &.{ .{ .email = "a@b" }, .{ .email = "" } };
    try h.expectAt(&users, "validation.not_empty", null, "[1].email");
    const array: [2]User = .{ .{ .email = "" }, .{ .email = "x" } };
    try h.expectAt(&array, "validation.not_empty", null, "[0].email");
    const nested: []const []const User = &.{ &.{}, &.{ .{ .email = "x" }, .{ .email = "" } } };
    try h.expectAt(&nested, "validation.not_empty", null, "[1][1].email");
    const optional_items: []const ?User = &.{ null, .{ .email = "" } };
    try h.expectAt(&optional_items, "validation.not_empty", null, "[1].email");
    var maybe: ?User = null;
    try h.expectValid(&maybe);
    maybe = .{ .email = "" };
    try h.expectAt(&maybe, "validation.not_empty", null, "email");
    var mutable: User = .{ .email = "" };
    try h.expectAt(&mutable, "validation.not_empty", null, "email");
}

test "a root behind a pointer that coerces to *const T is walked in place: an over-aligned or explicitly aligned value, a MemoryPool item" {
    var plain: Pinned = undefined;
    pin(&plain);
    try h.expectValid(&plain);
    try h.expectValid(@as(*const Pinned, &plain));
    var over_aligned: Pinned align(64) = undefined;
    pin(&over_aligned);
    try h.expectValid(&over_aligned);
    // An explicit alignment equal to the natural one is still a pointer type of its own.
    var naturally_aligned: Pinned align(@alignOf(Pinned)) = undefined;
    pin(&naturally_aligned);
    try h.expectValid(&naturally_aligned);
    var pool: std.heap.MemoryPool(Pinned) = .empty;
    defer pool.deinit(testing.allocator);
    const pooled = try pool.create(testing.allocator); // an explicitly aligned *align(N) Pinned
    pin(pooled);
    try h.expectValid(pooled);
    var array: [2]Pinned align(64) = undefined;
    for (&array) |*item| pin(item);
    try h.expectValid(&array);
}

const PackedHolder = packed struct { flag: u3 = 0, bits: Bits, rest: u5 = 0 };

test "a root behind an under-aligned, volatile or bit pointer is walked through a copy; an opaque root without rules is never read" {
    var user: User = .{ .email = "" };
    const under_aligned: *align(1) const User = &user;
    try h.expectAt(under_aligned, "validation.not_empty", "must not be empty", "email");
    const volatile_root: *volatile User = &user;
    try h.expectAt(volatile_root, "validation.not_empty", "must not be empty", "email");
    var holder: PackedHolder = .{ .bits = .{ .low = 1, .high = 0 } };
    try h.expectAt(&holder.bits, "validation.positive", "must be greater than 0", "high");
    // An opaque value could not be copied, and an opaque type has no alignment to compare.
    const handle: *volatile anyopaque = &user;
    try h.expectValid(handle);
    const aligned_handle: *align(@alignOf(User)) const anyopaque = @ptrCast(&user);
    try h.expectValid(aligned_handle);
}

test "roots without rules have no violations: a number, a string, an enum, a union, a slice of numbers, void" {
    try h.expectValid(&@as(u32, 0));
    try h.expectValid(&@as([]const u8, ""));
    try h.expectValid(&Color.blue);
    try h.expectValid(&Shape{ .circle = -1 });
    try h.expectValid(&@as([]const u32, &.{ 0, 0 }));
    try h.expectValid(&{});
}

// Each level holds two fields of the next one: 2^30 paths lead to L30.
const L0 = struct { a: L1 = .{}, b: L1 = .{} };
const L1 = struct { a: L2 = .{}, b: L2 = .{} };
const L2 = struct { a: L3 = .{}, b: L3 = .{} };
const L3 = struct { a: L4 = .{}, b: L4 = .{} };
const L4 = struct { a: L5 = .{}, b: L5 = .{} };
const L5 = struct { a: L6 = .{}, b: L6 = .{} };
const L6 = struct { a: L7 = .{}, b: L7 = .{} };
const L7 = struct { a: L8 = .{}, b: L8 = .{} };
const L8 = struct { a: L9 = .{}, b: L9 = .{} };
const L9 = struct { a: L10 = .{}, b: L10 = .{} };
const L10 = struct { a: L11 = .{}, b: L11 = .{} };
const L11 = struct { a: L12 = .{}, b: L12 = .{} };
const L12 = struct { a: L13 = .{}, b: L13 = .{} };
const L13 = struct { a: L14 = .{}, b: L14 = .{} };
const L14 = struct { a: L15 = .{}, b: L15 = .{} };
const L15 = struct { a: L16 = .{}, b: L16 = .{} };
const L16 = struct { a: L17 = .{}, b: L17 = .{} };
const L17 = struct { a: L18 = .{}, b: L18 = .{} };
const L18 = struct { a: L19 = .{}, b: L19 = .{} };
const L19 = struct { a: L20 = .{}, b: L20 = .{} };
const L20 = struct { a: L21 = .{}, b: L21 = .{} };
const L21 = struct { a: L22 = .{}, b: L22 = .{} };
const L22 = struct { a: L23 = .{}, b: L23 = .{} };
const L23 = struct { a: L24 = .{}, b: L24 = .{} };
const L24 = struct { a: L25 = .{}, b: L25 = .{} };
const L25 = struct { a: L26 = .{}, b: L26 = .{} };
const L26 = struct { a: L27 = .{}, b: L27 = .{} };
const L27 = struct { a: L28 = .{}, b: L28 = .{} };
const L28 = struct { a: L29 = .{}, b: L29 = .{} };
const L29 = struct { a: L30 = .{}, b: L30 = .{} };
const L30 = struct {}; // zero-sized: the graph has 2^30 paths but no bytes

const DagRoot = struct {
    dag: L0 = .{},
    item: Item = .{ .name = "" },
};

test "the search for rules looks at each type once: a type graph with 2^30 paths compiles" {
    try h.expectAt(&DagRoot{}, "validation.not_empty", null, "item.name");
}
