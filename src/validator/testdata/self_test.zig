//! `validateSelf` and `v.fail` at run time: when a struct's `validateSelf`
//! runs, where its violation is reported, and how a hand-built result is
//! checked.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

// ------------------------------------------------------------- order of the calls

var self_log: [16][]const u8 = undefined;
var self_log_len: usize = 0;

fn logSelf(name: []const u8) void {
    self_log[self_log_len] = name;
    self_log_len += 1;
}

fn expectLog(expected: []const []const u8) !void {
    errdefer {
        std.debug.print("\n  validateSelf calls:", .{});
        for (self_log[0..self_log_len]) |entry| std.debug.print(" {s}", .{entry});
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(expected.len, self_log_len);
    for (expected, self_log[0..self_log_len]) |e, a| try testing.expectEqualStrings(e, a);
}

const Leaf = struct {
    id: []const u8,
    a: u32,
    fail_self: bool = false,
    pub const field_rules = .{ .a = v.positive };
    pub fn validateSelf(leaf: *const Leaf) ?v.Violation {
        logSelf(leaf.id);
        if (leaf.fail_self) return v.fail(Leaf, .a, "t.leaf_self", "leaf validateSelf failed");
        return null;
    }
};
const Mid = struct {
    leaves: []const Leaf,
    pub fn validateSelf(_: *const Mid) ?v.Violation {
        logSelf("mid");
        return null;
    }
};
const Top = struct {
    mid: Mid,
    other: Leaf,
    pub fn validateSelf(_: *const Top) ?v.Violation {
        logSelf("top");
        return null;
    }
};

test "validateSelf runs after all fields of its struct, nested ones before outer ones" {
    const value: Top = .{ .mid = .{ .leaves = &.{ .{ .id = "leaf0", .a = 1 }, .{ .id = "leaf1", .a = 1 } } }, .other = .{ .id = "other", .a = 1 } };
    self_log_len = 0;
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(0, report.violations.len);
    try expectLog(&.{ "leaf0", "leaf1", "mid", "other", "top" });
}

test "validateSelf runs only when nothing in its struct's subtree failed" {
    const value: Top = .{ .mid = .{ .leaves = &.{ .{ .id = "leaf0", .a = 1 }, .{ .id = "leaf1", .a = 0 } } }, .other = .{ .id = "other", .a = 1 } };
    self_log_len = 0;
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(1, report.violations.len);
    try h.expectField("mid.leaves[1].a", report.violations[0].field);
    // leaf1, mid and top contain the violation; leaf0 and other do not.
    try expectLog(&.{ "leaf0", "other" });

    // check stops at the first violation: nothing after it runs.
    self_log_len = 0;
    var buf: [64]u8 = undefined;
    try h.expectSame(.{ .code = "validation.positive", .message = "must be greater than 0", .field = "mid.leaves[1].a" }, v.check(&value, &buf).?);
    try expectLog(&.{"leaf0"});
}

test "a nested validateSelf violation keeps the outer validateSelf from running" {
    const value: Top = .{ .mid = .{ .leaves = &.{ .{ .id = "leaf0", .a = 1, .fail_self = true }, .{ .id = "leaf1", .a = 1 } } }, .other = .{ .id = "other", .a = 1 } };
    self_log_len = 0;
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(1, report.violations.len);
    try h.expectSame(.{ .code = "t.leaf_self", .message = "leaf validateSelf failed", .field = "mid.leaves[0].a" }, report.violations[0]);
    try expectLog(&.{ "leaf0", "leaf1", "other" });
}

// ------------------------------------------------------------- what keeps it from running

var span_calls: usize = 0;

const Span = struct {
    start: u32,
    end: u32,
    pub fn validateSelf(span: *const Span) ?v.Violation {
        span_calls += 1;
        if (span.end < span.start) return v.fail(@This(), .end, "t.end_before_start", "must not be before start");
        return null;
    }
};

fn startsAtOne(span: *const Span) bool {
    return span.start == 1;
}

const Booking = struct {
    span: Span,
    spans: []const Span,
    pub const field_rules = .{
        .span = v.custom("t.starts_at_one", "must start at 1", startsAtOne),
        .spans = v.each(v.custom("t.starts_at_one", "must start at 1", startsAtOne)),
    };
};

test "validateSelf does not run when the struct's own rule or its item rule failed" {
    span_calls = 0;
    const value: Booking = .{ .span = .{ .start = 2, .end = 1 }, .spans = &.{ .{ .start = 2, .end = 1 }, .{ .start = 1, .end = 0 } } };
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try testing.expectEqual(3, report.violations.len);
    try h.expectSame(.{ .code = "t.starts_at_one", .message = "must start at 1", .field = "span" }, report.violations[0]);
    try h.expectSame(.{ .code = "t.starts_at_one", .message = "must start at 1", .field = "spans[0]" }, report.violations[1]);
    try h.expectSame(.{ .code = "t.end_before_start", .message = "must not be before start", .field = "spans[1].end" }, report.violations[2]);
    try testing.expectEqual(1, span_calls); // spans[1] only
}

const MaybeSpans = struct {
    span: ?Span = null,
    list: ?[]const Span = null,
    items: []const ?Span = &.{},
};

test "a null optional skips the nested validateSelf; a present value runs it" {
    span_calls = 0;
    try h.expectValid(&MaybeSpans{ .items = &.{ null, null } });
    try testing.expectEqual(0, span_calls);
    try h.expectAll(&MaybeSpans{
        .span = .{ .start = 2, .end = 1 },
        .list = &.{.{ .start = 1, .end = 1 }},
        .items = &.{ null, .{ .start = 3, .end = 2 } },
    }, &.{
        .{ .code = "t.end_before_start", .field = "span.end" },
        .{ .code = "t.end_before_start", .field = "items[1].end" },
    });
}

// ------------------------------------------------------------- paths

const Whole = struct {
    ok: bool,
    pub fn validateSelf(w: *const Whole) ?v.Violation {
        if (!w.ok) return v.fail(Whole, null, "t.whole", "whole value is bad");
        return null;
    }
};
const Holder = struct {
    ranges: []const Span = &.{},
    wholes: []const Whole = &.{},
};

test "the returned field is appended to the struct's path; null gives the struct's own path" {
    try h.expectAll(&Holder{
        .ranges = &.{ .{ .start = 1, .end = 2 }, .{ .start = 1, .end = 2 }, .{ .start = 5, .end = 1 } },
        .wholes = &.{ .{ .ok = true }, .{ .ok = true }, .{ .ok = false } },
    }, &.{
        .{ .code = "t.end_before_start", .field = "ranges[2].end" },
        .{ .code = "t.whole", .field = "wholes[2]" },
    });
}

test "at the root, the returned field is the whole path and null means the root itself" {
    try h.expectAll(&Span{ .start = 2, .end = 1 }, &.{.{ .code = "t.end_before_start", .field = "end" }});
    try h.expectAll(&Whole{ .ok = false }, &.{.{ .code = "t.whole", .field = null }});
    try h.expectAll(&[_]Whole{ .{ .ok = true }, .{ .ok = false } }, &.{.{ .code = "t.whole", .field = "[1]" }});
    const wholes: []const Whole = &.{ .{ .ok = true }, .{ .ok = false } };
    try h.expectAll(&wholes, &.{.{ .code = "t.whole", .field = "[1]" }});
}

test "a validateSelf path that does not fit path_buf gives field = null with the code and message intact" {
    const value: Holder = .{ .ranges = &.{ .{ .start = 1, .end = 2 }, .{ .start = 1, .end = 2 }, .{ .start = 3, .end = 2 } } };
    var exact: ["ranges[2].end".len]u8 = undefined;
    try h.expectSame(.{ .code = "t.end_before_start", .message = "must not be before start", .field = "ranges[2].end" }, v.check(&value, &exact).?);
    var short: ["ranges[2].end".len - 1]u8 = undefined;
    try h.expectSame(.{ .code = "t.end_before_start", .message = "must not be before start", .field = null }, v.check(&value, &short).?);
}

const Guarded = struct {
    n: u32,
    pub const field_rules = .{ .n = v.positive };
    pub fn validateSelf(_: *const Guarded) ?v.Violation {
        return v.fail(Guarded, null, "t.guarded", "guarded rejected");
    }
};
const Outer = struct { guarded: Guarded };

test "a validateSelf violation reported after the fields of a struct whose path overflowed path_buf has field = null" {
    const value: Outer = .{ .guarded = .{ .n = 1 } };
    var big: [16]u8 = undefined;
    for (0.."guarded".len + 3) |size| {
        // guarded.n is pushed and popped before validateSelf runs: a "guarded" that did not fit must stay null.
        const got = v.check(&value, big[0..size]) orelse return error.NoViolation;
        try testing.expectEqualStrings("t.guarded", got.code);
        try testing.expectEqualStrings("guarded rejected", got.message);
        try h.expectField(if (size >= "guarded".len) "guarded" else null, got.field);
    }
}

// ------------------------------------------------------------- v.fail and hand-built results

test "v.fail returns the field name from the enum, or null, with its code and message" {
    try h.expectSame(.{ .code = "t.end_before_start", .message = "must not be before start", .field = "end" }, v.fail(Span, .end, "t.end_before_start", "must not be before start"));
    try h.expectSame(.{ .code = "t.whole", .message = "whole value is bad", .field = null }, v.fail(Whole, null, "t.whole", "whole value is bad"));
}

const InlineSelf = struct {
    n: u32,
    pub inline fn validateSelf(self: *const InlineSelf) ?v.Violation {
        if (self.n == 0) return v.fail(InlineSelf, .n, "t.zero", "must not be zero");
        return null;
    }
};

test "an inline fn validateSelf is accepted" {
    try h.expectAt(&InlineSelf{ .n = 0 }, "t.zero", "must not be zero", "n");
    try h.expectValid(&InlineSelf{ .n = 1 });
}

const Dynamic = struct {
    names: []const u8,
    pub fn validateSelf(d: *const Dynamic) ?v.Violation {
        // Hand-built, with a field name taken from the value at run time.
        return .{ .code = "app.dynamic", .message = "dynamic field", .field = d.names };
    }
};

test "a hand-built result is checked at run time and its path takes the field name from the type" {
    const storage = try testing.allocator.dupe(u8, "names");
    const value: Dynamic = .{ .names = storage };
    const report = try v.checkAll(testing.allocator, &value);
    defer report.deinit();
    try h.expectSame(.{ .code = "app.dynamic", .message = "dynamic field", .field = "names" }, report.violations[0]);
    @memset(storage, '#');
    testing.allocator.free(storage);
    // The path is still intact: it never pointed into the checked value.
    try testing.expectEqualStrings("names", report.violations[0].field.?);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("names", v.check(&Dynamic{ .names = "names" }, &buf).?.field.?);
}

const RootSelf = struct {
    ok: bool,
    pub fn validateSelf(r: *const RootSelf) ?v.Violation {
        if (!r.ok) return .{ .code = "t.root", .message = "root is bad" };
        return null;
    }
};

test "a hand-built result without a field at the root has field = null" {
    try h.expectAll(&RootSelf{ .ok = false }, &.{.{ .code = "t.root", .field = null }});
    try h.expectValid(&RootSelf{ .ok = true });
}

// ------------------------------------------------------------- the report cap

var capped_calls: usize = 0;

const Capped = struct {
    n: u32,
    pub const field_rules = .{ .n = v.positive };
    pub fn validateSelf(_: *const Capped) ?v.Violation {
        capped_calls += 1;
        return null;
    }
};

const Named = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const FullBefore = struct {
    names: []const Named,
    capped: Capped,
};

test "validateSelf does not run when the violation beyond the cap is in its struct's subtree" {
    const names: [v.max_report_violations]Named = @splat(.{ .name = "" });
    capped_calls = 0;
    {
        // The report is full but capped is clean: its validateSelf runs.
        const report = try v.checkAll(testing.allocator, &FullBefore{ .names = &names, .capped = .{ .n = 1 } });
        defer report.deinit();
        try testing.expect(!report.truncated);
        try testing.expectEqual(1, capped_calls);
    }
    {
        // capped.n is the violation beyond the cap: it is dropped, yet capped's subtree failed.
        const report = try v.checkAll(testing.allocator, &FullBefore{ .names = &names, .capped = .{ .n = 0 } });
        defer report.deinit();
        try testing.expect(report.truncated);
        try testing.expectEqual(1, capped_calls);
    }
}
