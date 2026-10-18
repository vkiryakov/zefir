//! An allocator that counts the bytes it holds for its owner, so a test
//! can see what a connection of `http.native` keeps between requests. Safe
//! from any number of threads when its child allocator is.

const std = @import("std");

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    /// Bytes allocated and not freed yet, as their owners asked for them.
    live: std.atomic.Value(usize) = .init(0),

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(c: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn liveBytes(c: *const CountingAllocator) usize {
        return c.live.load(.acquire);
    }

    fn of(ptr: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c = of(ptr);
        const memory = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = c.live.fetchAdd(len, .acq_rel);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c = of(ptr);
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.moved(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c = of(ptr);
        const moved_to = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.moved(memory.len, new_len);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c = of(ptr);
        c.child.rawFree(memory, alignment, ret_addr);
        _ = c.live.fetchSub(memory.len, .acq_rel);
    }

    fn moved(c: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            _ = c.live.fetchAdd(new_len - old_len, .acq_rel);
        } else {
            _ = c.live.fetchSub(old_len - new_len, .acq_rel);
        }
    }
};

test "the counting allocator counts what is live" {
    var counting: CountingAllocator = .init(std.testing.allocator);
    const a = counting.allocator();
    const first = try a.alloc(u8, 100);
    var second = try a.alloc(u8, 50);
    try std.testing.expectEqual(150, counting.liveBytes());
    second = try a.realloc(second, 80);
    try std.testing.expectEqual(180, counting.liveBytes());
    a.free(first);
    a.free(second);
    try std.testing.expectEqual(0, counting.liveBytes());
}
