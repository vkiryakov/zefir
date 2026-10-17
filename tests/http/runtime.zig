//! The zio runtimes that the probes and the end-to-end tests of zefir-http
//! run on: every scenario runs on one executor, then on four.

const std = @import("std");
const zio = @import("zio");

/// The number of executors of the runtime that runs the scenario now, for
/// the lines a scenario prints.
pub var executors: u8 = 0;

/// Runs `scenario` on zio with one executor, then with four, and names the
/// one that failed.
pub fn forEachRuntime(gpa: std.mem.Allocator, comptime scenario: fn (io: std.Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |count| {
        const runtime = try zio.Runtime.init(gpa, .{ .executors = .exact(count) });
        defer runtime.deinit();
        executors = count;
        defer executors = 0;
        scenario(runtime.io()) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ count, err });
            return err;
        };
    }
}
