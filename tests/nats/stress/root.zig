//! Stress tests of zefir-nats against the servers of the repository's
//! docker-compose.yml: 50,000 requests at once, a storm of cut
//! connections, and stopping a client while thousands of tasks wait in it.
//! `zig build stress` runs them in Debug and in ReleaseSafe, each on zio
//! with one executor and again with four.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");

/// Runs `scenario` on zio with one executor, then with four. The stacks of
/// the tasks reserve 1 MiB of addresses each instead of 8, as tens of
/// thousands of tasks run at once; the 256 KiB a stack starts with is far
/// more than a task of these tests needs.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{
            .executors = .exact(executors),
            .stack_pool = .{ .maximum_size = 1024 * 1024, .committed_size = 256 * 1024 },
        });
        defer runtime.deinit();
        std.debug.print("  {t}, {d} executor(s)\n", .{ @import("builtin").mode, executors });
        scenario(runtime.io()) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

/// An allocator that counts the bytes its child holds, now and at most.
/// It is as thread-safe as its child.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    current: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    pub fn allocator(c: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Starts measuring the peak from what is held now; returns it.
    pub fn resetPeak(c: *CountingAllocator) usize {
        const now = c.current.load(.monotonic);
        c.peak.store(now, .monotonic);
        return now;
    }

    fn grew(c: *CountingAllocator, bytes: usize) void {
        const now = c.current.fetchAdd(bytes, .monotonic) + bytes;
        _ = c.peak.fetchMax(now, .monotonic);
    }

    fn changed(c: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) c.grew(new_len - old_len) else _ = c.current.fetchSub(old_len - new_len, .monotonic);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        const memory = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.grew(len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.changed(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        const moved = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.changed(memory.len, new_len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *CountingAllocator = @ptrCast(@alignCast(context));
        c.child.rawFree(memory, alignment, ret_addr);
        _ = c.current.fetchSub(memory.len, .monotonic);
    }
};

pub fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// The most memory the process has held so far, in MiB; null where the
/// system does not say (Windows).
pub fn maxRssMiB() ?usize {
    const os = @import("builtin").os.tag;
    if (os == .windows) return null;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const max: usize = @intCast(usage.maxrss);
    // macOS reports bytes, Linux KiB.
    return if (os.isDarwin()) max / (1024 * 1024) else max / 1024;
}

test {
    _ = @import("requests.zig");
    _ = @import("storm.zig");
    _ = @import("shutdown.zig");
}
