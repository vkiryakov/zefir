//! Debug build: `scheduler.Worker.deinit` while another task waits in the
//! worker's `wait` panics: it would free what that task still reads.
//! build.zig runs this program and checks the panic message on stderr and
//! the exit code 3 of the panic handler below.
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

const Worker = scheduler.Worker(struct { reminder: *Reminder });

fn waitFor(worker: *Worker, io: std.Io, entered: *std.Io.Event) void {
    entered.set(io);
    worker.wait(io) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var memory: scheduler.MemoryStore = .init(init.gpa, io, .{});
    defer memory.deinit();
    var reminder: Reminder = .{};
    var worker: Worker = try .init(init.gpa, io, memory.store(), .{ .reminder = &reminder }, .{});
    try worker.start(io);
    var entered: std.Io.Event = .unset;
    var waiter = try io.concurrent(waitFor, .{ &worker, io, &entered });
    defer waiter.await(io);
    entered.waitUncancelable(io);
    // Room for the waiter to get inside wait.
    try io.sleep(.fromMilliseconds(500), .awake);

    // The mistake: deinit while another task is in wait.
    worker.deinit(io);
}
