//! Memory: `checkAll` allocates only from the allocator it is given, frees
//! everything in `Report.deinit` and leaks nothing when an allocation fails;
//! `check` allocates nothing.
const std = @import("std");
const v = @import("validator");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Item = struct {
    name: []const u8,
    qty: u32,
    pub const field_rules = .{ .name = v.notEmpty, .qty = v.positive };
};

const Order = struct {
    items: []const Item,
    note: ?[]const u8 = null,
    pub const field_rules = .{ .items = v.notEmpty, .note = v.notEmpty };
};

/// Three violations: items[0].name, items[0].qty and items[2].name.
const bad_order: Order = .{ .items = &.{ .{ .name = "", .qty = 0 }, .{ .name = "x", .qty = 5 }, .{ .name = "", .qty = 1 } }, .note = "n" };

const Named = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Many = struct { items: []const Named };

fn checkAllOrder(gpa: Allocator, order: *const Order) !void {
    const report = try v.checkAll(gpa, order);
    defer report.deinit();
    try testing.expectEqual(3, report.violations.len);
    try testing.expectEqualStrings("items[2].name", report.violations[2].field.?);
}

fn checkAllTruncated(gpa: Allocator, many: *const Many) !void {
    const report = try v.checkAll(gpa, many);
    defer report.deinit();
    try testing.expectEqual(v.max_report_violations, report.violations.len);
    try testing.expect(report.truncated);
}

test "checkAll returns error.OutOfMemory and leaks nothing when any allocation fails: several violations" {
    try testing.checkAllAllocationFailures(testing.allocator, checkAllOrder, .{&bad_order});
}

test "checkAll returns error.OutOfMemory and leaks nothing when any allocation fails: a truncated report" {
    const items: [150]Named = @splat(.{ .name = "" });
    try testing.checkAllAllocationFailures(testing.allocator, checkAllTruncated, .{&Many{ .items = &items }});
}

/// Counts the live allocations made through it.
const Counting = struct {
    child: Allocator,
    live: usize = 0,
    total: usize = 0,

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.live += 1;
        c.total += 1;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        return c.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        return c.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret_addr);
        c.live -= 1;
    }
};

test "checkAll allocates only from the given allocator, and deinit frees all of it" {
    var counting: Counting = .{ .child = testing.allocator };
    const report = try v.checkAll(counting.allocator(), &bad_order);
    try testing.expectEqual(3, report.violations.len);
    try testing.expect(counting.total > 0);
    try testing.expect(counting.live > 0); // the report owns its memory until deinit
    report.deinit();
    try testing.expectEqual(0, counting.live);

    // A valid value gets a report too, which must be freed the same way.
    var counting_valid: Counting = .{ .child = testing.allocator };
    const valid: Order = .{ .items = &.{.{ .name = "a", .qty = 1 }} };
    const empty = try v.checkAll(counting_valid.allocator(), &valid);
    try testing.expectEqual(0, empty.violations.len);
    empty.deinit();
    try testing.expectEqual(0, counting_valid.live);
}

test "check allocates nothing: it also runs at compile time, where no allocator exists" {
    comptime {
        var buf: [64]u8 = undefined;
        const got = v.check(&bad_order, &buf) orelse @compileError("expected a violation");
        if (!std.mem.eql(u8, got.code, "validation.not_empty")) @compileError("wrong code: " ++ got.code);
        if (!std.mem.eql(u8, got.field.?, "items[0].name")) @compileError("wrong path: " ++ got.field.?);
        const valid: Order = .{ .items = &.{.{ .name = "a", .qty = 1 }} };
        if (v.check(&valid, &buf) != null) @compileError("expected no violation");
    }
}
