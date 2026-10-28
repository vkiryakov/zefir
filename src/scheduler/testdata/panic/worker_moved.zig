//! Debug build: a call on a copy of a `scheduler.Worker` made after its
//! `start` panics: the tasks of the worker point to the original. build.zig
//! runs this program and checks the panic message on stderr and the exit
//! code 3 of the panic handler below.
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

const Reminder = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "reminder" };

    pub fn run(self: *Reminder, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

pub fn main(init: std.process.Init) !void {
    var memory: scheduler.MemoryStore = .init(init.gpa, init.io, .{});
    defer memory.deinit();
    var reminder: Reminder = .{};
    var worker: scheduler.Worker(struct { reminder: *Reminder }) = try .init(init.gpa, init.io, memory.store(), .{ .reminder = &reminder }, .{});
    defer worker.deinit(init.io);
    try worker.start(init.io);

    // The mistake: a copy of the worker after its start.
    var moved = worker;
    moved.requestStop(init.io);
}
