//! The zio runtimes that the end-to-end tests of zefir.App run on: every
//! scenario runs on one executor, then on four.

const std = @import("std");
const zio = @import("zio");

/// The number of executors of the runtime that runs the scenario now, for
/// the lines a scenario prints.
pub var executors: u8 = 0;

/// Runs `scenario` on zio with one executor, then with four, and names the
/// one that failed. Both run even when the first fails, so that a run
/// shows how each behaves; the first error is returned.
pub fn forEachRuntime(gpa: std.mem.Allocator, comptime scenario: fn (io: std.Io) anyerror!void) !void {
    var first: ?anyerror = null;
    for ([_]u8{ 1, 4 }) |count| {
        const runtime = try zio.Runtime.init(gpa, .{ .executors = .exact(count) });
        defer runtime.deinit();
        executors = count;
        defer executors = 0;
        scenario(runtime.io()) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ count, err });
            if (first == null) first = err;
        };
    }
    if (first) |err| return err;
}

/// Ends the process with code 4 when a scenario runs longer than its time:
/// a hang fails at once, by name.
pub const Watchdog = struct {
    future: std.Io.Future(void),

    pub fn start(io: std.Io, name: []const u8, seconds: i64) !Watchdog {
        return .{ .future = try io.concurrent(watch, .{ io, name, seconds }) };
    }

    pub fn stop(w: *Watchdog, io: std.Io) void {
        w.future.cancel(io);
    }

    fn watch(io: std.Io, name: []const u8, seconds: i64) void {
        io.sleep(.fromSeconds(seconds), .awake) catch return;
        std.debug.print("\"{s}\" still runs after {d} s on zio x{d}: a hang\n", .{ name, seconds, executors });
        std.process.exit(4);
    }
};
