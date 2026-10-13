//! Debug build: calls that break the rules of `rpc.transport.Pending` panic
//! with a message that names the rule. build.zig runs this program once per
//! case, the first argument, and checks the panic message on stderr and the
//! exit code 3 of the panic handler below.
const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

fn ignore(context: *anyopaque) void {
    _ = context;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.NoCase;
    const case = args[1];
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(1));

    var pending: rpc.transport.Pending = try .init(init.gpa, .{ .max_pending = 2 });
    const slot = try pending.acquire(io);
    if (std.mem.eql(u8, case, "release_twice")) {
        pending.release(io, slot);
        pending.release(io, slot);
    } else if (std.mem.eql(u8, case, "wait_after_release")) {
        pending.release(io, slot);
        _ = try pending.wait(io, slot, deadline);
    } else if (std.mem.eql(u8, case, "wait_twice")) {
        var message: u8 = 0;
        _ = pending.complete(io, slot.id, .{ .response = .{ .status = .ok }, .context = &message, .release = ignore });
        _ = try pending.wait(io, slot, deadline);
        _ = try pending.wait(io, slot, deadline);
    } else if (std.mem.eql(u8, case, "deinit_in_use")) {
        pending.deinit();
    } else {
        return error.UnknownCase;
    }
    std.debug.print("no panic: {s}\n", .{case});
    std.process.exit(0);
}
