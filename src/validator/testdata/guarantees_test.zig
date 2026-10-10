//! The walk's guarantees: `checkAll` reports every violation in walk order,
//! one per value; the same value always gives the same violations; values
//! are only read, never normalized; there is no global state; each value is
//! visited once per path.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

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

test "checkAll reports every violation in walk order: fields in declaration order, depth first, items by index" {
    const value: Ordered = .{ .b = 0, .a = 0, .pair = .{ .p = 0, .q = 0 }, .items = &.{ .{ .p = 0, .q = 1 }, .{ .p = 1, .q = 0 }, .{ .p = 0, .q = 0 } }, .y = 0 };
    try h.expectAll(&value, &.{
        .{ .code = "validation.positive", .field = "b" },
        .{ .code = "validation.positive", .field = "a" },
        .{ .code = "validation.positive", .field = "pair.p" },
        .{ .code = "validation.positive", .field = "pair.q" },
        .{ .code = "validation.positive", .field = "items[0].p" },
        .{ .code = "validation.positive", .field = "items[1].q" },
        .{ .code = "validation.positive", .field = "items[2].p" },
        .{ .code = "validation.positive", .field = "items[2].q" },
        .{ .code = "validation.positive", .field = "y" },
    });
}

var later_calls = std.atomic.Value(usize).init(0);

fn countLater(_: u32) bool {
    _ = later_calls.fetchAdd(1, .monotonic);
    return true;
}

const Siblings = struct {
    first: u32,
    second: u32,
    third: u32,
    pub const field_rules = .{ .first = v.positive, .second = v.custom("t.later", "later rejected", countLater), .third = v.positive };
};

test "check stops at the first violation; checkAll goes on with the next sibling" {
    const value: Siblings = .{ .first = 0, .second = 1, .third = 0 };
    later_calls.store(0, .monotonic);
    var buf: [32]u8 = undefined;
    try h.expectSame(.{ .code = "validation.positive", .message = "must be greater than 0", .field = "first" }, v.check(&value, &buf) orelse return error.NoViolation);
    try testing.expectEqual(0, later_calls.load(.monotonic));
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(1, later_calls.load(.monotonic));
    try testing.expectEqual(2, report.violations.len);
    try h.expectField("first", report.violations[0].field);
    try h.expectField("third", report.violations[1].field);
}

fn notRejected(entry: *const Entry) bool {
    return !std.mem.eql(u8, entry.tag, "reject");
}

const Entry = struct {
    name: []const u8,
    tag: []const u8 = "ok",
    pub const field_rules = .{ .name = v.notEmpty };
};

const Entries = struct {
    entries: []const Entry,
    pub const field_rules = .{ .entries = v.each(v.custom("t.rejected", "entry rejected", notRejected)) };
};

fn never(_: u32) bool {
    return false;
}

test "checkAll reports at most one violation per value: a failed item is not descended into, the next items are" {
    // entries[1].name is empty too: descending into the rejected item would report it.
    try h.expectAll(&Entries{ .entries = &.{ .{ .name = "" }, .{ .name = "", .tag = "reject" }, .{ .name = "" } } }, &.{
        .{ .code = "validation.not_empty", .field = "entries[0].name" },
        .{ .code = "t.rejected", .field = "entries[1]" },
        .{ .code = "validation.not_empty", .field = "entries[2].name" },
    });
    // Two failing own rules: only the first is reported (expectFail expects exactly one violation from checkAll).
    try h.expectFail(u32, .{ v.custom("t.a", "a failed", never), v.custom("t.b", "b failed", never) }, 0, "t.a", "a failed");
}

const Leaf = struct {
    n: u32,
    pub const field_rules = .{ .n = v.positive };
};

fn alwaysRejected(_: *const Leaf) bool {
    return false;
}

const Failing = struct {
    leaf: Leaf,
    pub const field_rules = .{ .leaf = .{ v.custom("t.first", "first rule failed", alwaysRejected), v.custom("t.second", "second rule failed", alwaysRejected) } };
};

test "checkAll: a value whose own rule failed has that one violation only; later own rules do not run and nothing inside it is visited" {
    // leaf.n = 0 would add leaf.n if the walk descended into leaf, and t.second if it ran the next rule.
    try h.expectAll(&Failing{ .leaf = .{ .n = 0 } }, &.{.{ .code = "t.first", .field = "leaf" }});
}

fn notAbc(s: []const u8) bool {
    return !std.mem.eql(u8, s, "abc");
}

const Rows = struct {
    rows: []const []const []const u8,
    pub const field_rules = .{ .rows = v.each(.{ v.notEmpty, v.each(.{ v.notEmpty, v.custom("t.not_abc", "must not be abc", notAbc) }) }) };
};

test "checkAll walks nested each level by level: every failing row and cell once" {
    try h.expectAll(&Rows{ .rows = &.{ &.{ "a", "" }, &.{}, &.{ "abc", "ok", "" } } }, &.{
        .{ .code = "validation.not_empty", .field = "rows[0][1]" },
        .{ .code = "validation.not_empty", .field = "rows[1]" },
        .{ .code = "t.not_abc", .field = "rows[2][0]" },
        .{ .code = "validation.not_empty", .field = "rows[2][2]" },
    });
}

const Item = struct {
    name: []const u8,
    qty: u32,
    pub const field_rules = .{ .name = v.notEmpty, .qty = v.positive };
};

fn notSpam(note: []const u8) bool {
    return !std.mem.eql(u8, note, "spam");
}

const Order = struct {
    items: []const Item,
    note: ?[]const u8 = null,
    pub const field_rules = .{ .items = v.notEmpty, .note = v.custom("orders.spam", "must not be spam", notSpam) };
};

/// Lives in read-only memory: a write by the validator would crash the test.
const frozen: Order = .{ .items = &.{ .{ .name = "", .qty = 0 }, .{ .name = "x", .qty = 5 }, .{ .name = "", .qty = 1 } }, .note = "spam" };

const frozen_violations = [_]h.Expected{
    .{ .code = "validation.not_empty", .field = "items[0].name" },
    .{ .code = "validation.positive", .field = "items[0].qty" },
    .{ .code = "validation.not_empty", .field = "items[2].name" },
    .{ .code = "orders.spam", .field = "note" },
};

test "deterministic: the same value gives the same violations in the same order" {
    const first = try v.checkAll(testing.allocator, &frozen);
    defer first.deinit();
    for (0..10) |_| {
        const again = try v.checkAll(testing.allocator, &frozen);
        defer again.deinit();
        try testing.expectEqual(first.violations.len, again.violations.len);
        for (first.violations, again.violations) |a, b| try h.expectSame(a, b);
    }
}

test "read-only: a const value in read-only memory is checked; a var value is byte-identical afterwards" {
    try h.expectAll(&frozen, &frozen_violations);
    var names = [_][3]u8{ "  a".*, "b  ".*, " c ".* };
    var items = [_]Item{ .{ .name = &names[0], .qty = 0 }, .{ .name = &names[1], .qty = 1 }, .{ .name = &names[2], .qty = 2 } };
    var order: Order = .{ .items = &items, .note = "  padded  " };
    const before_order = std.mem.toBytes(order);
    const before_items = std.mem.toBytes(items);
    const before_names = std.mem.toBytes(names);
    var buf: [64]u8 = undefined;
    _ = v.check(&order, &buf);
    const report = try v.checkAll(testing.allocator, &order);
    report.deinit();
    try testing.expectEqualSlices(u8, &before_order, &std.mem.toBytes(order));
    try testing.expectEqualSlices(u8, &before_items, &std.mem.toBytes(items));
    try testing.expectEqualSlices(u8, &before_names, &std.mem.toBytes(names));
}

fn isAdmin(role: []const u8) bool {
    return std.mem.eql(u8, role, "admin");
}

fn isPrecomposedE(word: []const u8) bool {
    return std.mem.eql(u8, word, "\u{00C9}");
}

const Text = struct {
    role: []const u8 = "admin",
    word: []const u8 = "\u{00C9}",
    pub const field_rules = .{
        .role = .{ v.notEmpty, v.custom("t.admin", "must be admin", isAdmin) },
        .word = v.custom("t.e_acute", "must be a precomposed E with acute", isPrecomposedE),
    };
};

test "nothing is normalized: rules see the bytes as they are, untrimmed, in their case and Unicode form" {
    try h.expectValid(&Text{});
    try h.expectAt(&Text{ .role = " " }, "t.admin", null, "role"); // whitespace is present and non-empty
    try h.expectAt(&Text{ .role = "admin " }, "t.admin", null, "role"); // not trimmed
    try h.expectAt(&Text{ .role = "Admin" }, "t.admin", null, "role"); // no case folding
    try h.expectAt(&Text{ .word = "E\u{0301}" }, "t.e_acute", null, "word"); // no Unicode normalization
}

const thread_rounds = 500;

/// Counts the rounds in which `check` and `checkAll` gave the expected
/// result; `path_buf` and the memory `checkAll` allocates from belong to this
/// thread, so the threads share only the checked value (a shared allocator
/// would make the test measure its lock, not the validator).
fn worker(agreed: *[2]usize) void {
    var buf: [64]u8 = undefined;
    var memory: [16 * 1024]u8 = undefined;
    for (0..thread_rounds) |_| {
        const got = v.check(&frozen, &buf) orelse continue;
        if (std.mem.eql(u8, got.field orelse "", "items[0].name")) agreed[0] += 1;
        var fba: std.heap.FixedBufferAllocator = .init(&memory);
        const report = v.checkAll(fba.allocator(), &frozen) catch continue;
        defer report.deinit();
        if (report.violations.len == frozen_violations.len and std.mem.eql(u8, report.violations[3].field orelse "", "note")) agreed[1] += 1;
    }
}

test "no global state: 8 threads check one value at once, each with its own path_buf, and agree" {
    var agreed: [8][2]usize = @splat(.{ 0, 0 });
    var threads: [8]std.Thread = undefined;
    for (&threads, &agreed) |*thread, *counts| thread.* = try std.Thread.spawn(.{}, worker, .{counts});
    for (threads) |thread| thread.join();
    for (agreed) |counts| try testing.expectEqual([2]usize{ thread_rounds, thread_rounds }, counts);
}

var item_rule_calls = std.atomic.Value(usize).init(0);
var name_rule_calls = std.atomic.Value(usize).init(0);

fn countItem(_: *const Counted) bool {
    _ = item_rule_calls.fetchAdd(1, .monotonic);
    return true;
}

fn countName(_: []const u8) bool {
    _ = name_rule_calls.fetchAdd(1, .monotonic);
    return true;
}

const Counted = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.custom("t.name", "name rejected", countName) };
};

const Big = struct {
    items: []const Counted,
    pub const field_rules = .{ .items = v.each(v.custom("t.item", "item rejected", countItem)) };
};

test "each value is visited once: one walk calls each rule once per item" {
    const n = 1000;
    const items: [n]Counted = @splat(.{ .name = "x" });
    var buf: [64]u8 = undefined;
    item_rule_calls.store(0, .monotonic);
    name_rule_calls.store(0, .monotonic);
    try testing.expectEqual(null, v.check(&Big{ .items = &items }, &buf));
    try testing.expectEqual(n, item_rule_calls.load(.monotonic));
    try testing.expectEqual(n, name_rule_calls.load(.monotonic));
    const report = try v.checkAll(testing.allocator, &Big{ .items = &items });
    defer report.deinit();
    try testing.expectEqual(2 * n, item_rule_calls.load(.monotonic));
    try testing.expectEqual(2 * n, name_rule_calls.load(.monotonic));
}

const Address = struct {
    city: []const u8,
    pub const field_rules = .{ .city = v.notEmpty };
};

const Shared = struct {
    home: Address,
    list: []const Address,
};

test "a value reachable on two paths is checked on each path" {
    const one: Address = .{ .city = "" };
    try h.expectAll(&Shared{ .home = one, .list = &.{ one, one } }, &.{
        .{ .code = "validation.not_empty", .field = "home.city" },
        .{ .code = "validation.not_empty", .field = "list[0].city" },
        .{ .code = "validation.not_empty", .field = "list[1].city" },
    });
}
