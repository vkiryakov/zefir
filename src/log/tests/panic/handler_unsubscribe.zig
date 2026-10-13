//! Debug build: a subscriber's handler that removes its own subscription
//! panics, since `unsubscribe` would wait for the handler's own thread.
//! build.zig runs this program and checks the panic message on stderr and
//! the exit code 3 of the panic handler below.
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

const Leaver = struct {
    logger: log.Logger,
    /// Set before the first record is logged.
    id: log.SubscriptionId = undefined,
    returned: std.atomic.Value(bool) = .init(false),

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const l: *Leaver = @ptrCast(@alignCast(context orelse return error.NoContext));
        l.logger.unsubscribe(l.id);
        l.returned.store(true, .seq_cst);
    }
};

pub fn main(init: std.process.Init) !void {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .output = .{ .writer = &sink.writer } });
    var leaver: Leaver = .{ .logger = logger };
    leaver.id = try logger.subscribe(.{ .levels = &.{.err}, .context = &leaver, .handler = Leaver.handler });
    logger.err("disk full", .{});
    exitWithoutPanic(init.io, &leaver.returned, "the handler's unsubscribe");
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
