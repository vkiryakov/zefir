//! End-to-end tests of zefir-nats against the servers of docker-compose.yml.
//! Every scenario runs on zio with one executor and again with four, and
//! sees only `std.Io`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");

/// The servers of docker-compose.yml.
pub const servers = struct {
    pub const plain = "nats://127.0.0.1:14222";
    pub const auth = "nats://127.0.0.1:14223";
    pub const tls = "nats://127.0.0.1:14224";
    pub const tls_first = "nats://127.0.0.1:14225";
    pub const cluster: []const []const u8 = &.{ "nats://127.0.0.1:14226", "nats://127.0.0.1:14227", "nats://127.0.0.1:14228" };
};

/// Runs `scenario` on zio with one executor, then with four.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        scenario(runtime.io()) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

test {
    _ = @import("connection.zig");
}
