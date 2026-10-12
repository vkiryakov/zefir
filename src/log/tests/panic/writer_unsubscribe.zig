//! Debug build: in queued mode, an output writer that calls `unsubscribe`
//! panics, as a handler that calls it does: the handler it would wait for
//! may itself wait for room in the queue, which only the writer thread
//! makes. build.zig runs this program and checks the panic message on stderr
//! and the exit code 3 of the panic handler below.
const std = @import("std");
const log = @import("log");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// An output that removes a subscription each time the writer thread
/// writes to it.
const Remover = struct {
    /// Both set before the first record is logged.
    logger: ?log.Logger = null,
    id: log.SubscriptionId = undefined,
    returned: std.atomic.Value(bool) = .init(false),
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const r: *Remover = @alignCast(@fieldParentPtr("writer", w));
        r.logger.?.unsubscribe(r.id);
        r.returned.store(true, .seq_cst);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        return n + data[data.len - 1].len * splat;
    }
};

fn ignore(_: ?*anyopaque, _: *const log.Event) anyerror!void {}

pub fn main(init: std.process.Init) !void {
    var remover: Remover = .{};
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &remover.writer } });
    remover.id = try logger.subscribe(.{ .levels = &.{.err}, .handler = ignore });
    remover.logger = logger;
    logger.info("to the writer thread", .{});
    exitWithoutPanic(init.io, &remover.returned, "the writer thread's unsubscribe");
}

/// Waits up to 2 s for the panic, which ends the process. Without one it
/// says whether the call returned and exits with 0, without `deinit`: a
/// thread stuck in the call would keep `deinit` waiting.
fn exitWithoutPanic(io: std.Io, returned: *const std.atomic.Value(bool), call: []const u8) noreturn {
    var waited: usize = 0;
    while (!returned.load(.seq_cst) and waited < 2000) : (waited += 1) io.sleep(.fromMilliseconds(1), .awake) catch {};
    std.debug.print("no panic: {s} {s}\n", .{ call, if (returned.load(.seq_cst)) "returned" else "is still waiting" });
    std.process.exit(0);
}
