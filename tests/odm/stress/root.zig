//! Stress tests of zefir-odm against mongo-auth of the repository's
//! docker-compose.yml: a storm of sessions and calls over 20 tenants on two
//! connections, each replaced every 200 ms by turns with two users, while
//! tenants are removed and provisioned again; and a shutdown in the middle
//! of that load. `zig build stress` runs them in Debug and in ReleaseSafe,
//! each on zio with one executor and again with four, under the time limit
//! of the end-to-end tests; the test runner checks that all the memory
//! comes back.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");
const e2e = @import("e2e");

/// Runs `scenario` on zio with one executor, then with four.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        std.debug.print("  {t}, {d} executor(s)\n", .{ builtin.mode, executors });
        e2e.withinTimeLimit(runtime.io(), scenario) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

test {
    _ = @import("storm.zig");
}
