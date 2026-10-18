//! End-to-end tests of zefir-mongo and of its native driver against the
//! mongod servers of the repository's docker-compose.yml, profile
//! `mongo`. Every scenario runs on zio with one executor and again with
//! four, under a time limit, and sees only `std.Io`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");

pub const RawConn = @import("RawConn.zig");
pub const Proxy = @import("Proxy.zig");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// mongo-plain: no authentication, test commands on.
    pub const plain_port: u16 = 27117;
    /// mongo-auth: --auth with the users of init/users.js, test commands
    /// on.
    pub const auth_port: u16 = 27118;
    /// mongo-ghost: a member of a replica set that is not initialized.
    pub const ghost_port: u16 = 27121;
};

/// The database the tests write to; each scenario drops what it made.
pub const database = "zefir_e2e";

/// How long one scenario may take on one runtime.
const time_limit: Io.Duration = .fromSeconds(120);

/// Runs `scenario` on zio with one executor, then with four.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        withinTimeLimit(runtime.io(), scenario) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

/// Runs `scenario` in a task of its own and cancels it when it takes
/// longer than `time_limit`: a server that stops answering fails the test
/// instead of hanging it.
fn withinTimeLimit(io: Io, comptime scenario: fn (Io) anyerror!void) anyerror!void {
    const Race = union(enum) {
        done: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, scenario, .{io});
    select.concurrent(.timer, Io.sleep, .{ io, time_limit, .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .done => |result| result,
        .timer => error.TestTimedOut,
    };
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(RawConn);
    _ = @import("wire.zig");
    _ = @import("script_vs_mongod.zig");
    _ = @import("Proxy.zig");
    _ = @import("conformance.zig");
    _ = @import("crud.zig");
    _ = @import("connect.zig");
    _ = @import("auth.zig");
}
