//! Debug build: a call of `scheduler.MemoryStore` that comes on another
//! `std.Io` than the one of `MemoryStore.init` panics: every wait of the
//! store goes through its own. build.zig runs this program and checks the
//! panic message on stderr and the exit code 3 of the panic handler below.
const std = @import("std");
const scheduler = @import("scheduler");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    var memory: scheduler.MemoryStore = .init(init.gpa, init.io, .{});
    defer memory.deinit();
    const store = memory.store();

    // The mistake: the io of a second std.Io.Threaded, not the store's.
    var other: std.Io.Threaded = .init(init.gpa, .{});
    defer other.deinit();
    const ref: scheduler.Ref = .{ .job = "send-invoice", .key = "order-42" };
    _ = try store.get(other.io(), .root, &ref, .{ .allocator = init.gpa });
}
