//! End-to-end tests of zefir-mongo against the mongod servers of the
//! repository's docker-compose.yml, profile `mongo`. Every scenario runs
//! on zio with one executor and again with four, under a time limit, and
//! sees only `std.Io`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// mongo-plain: no authentication, test commands on.
    pub const plain_port: u16 = 27117;
    /// mongo-auth: --auth with the users of init/users.js, test commands
    /// on.
    pub const auth_port: u16 = 27118;
    /// mongo-stall: no authentication; the tests pause it by its container
    /// name, so that it stops answering.
    pub const stall_port: u16 = 27119;
    pub const stall_container = "zefir-mongo-e2e-stall";
    /// mongo-restart: no authentication, test commands on; the tests
    /// restart it by its container name.
    pub const restart_port: u16 = 27120;
    pub const restart_container = "zefir-mongo-e2e-restart";
    /// mongo-ghost: a member of a replica set that is not initialized.
    pub const ghost_port: u16 = 27121;
};

/// Runs `docker` with `args` and fails unless it succeeds.
pub fn docker(args: []const []const u8) !void {
    testing.allocator.free(try dockerOutput(args));
}

/// Runs `docker` with `args` and returns what it printed; the caller frees
/// it with `testing.allocator`. It runs on the test's own `std.Io`,
/// whatever runtime the client under test uses.
pub fn dockerOutput(args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = "docker";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1] });
    defer testing.allocator.free(result.stderr);
    errdefer testing.allocator.free(result.stdout);
    if (!result.term.success()) {
        std.debug.print("docker {s} failed: {s}\n", .{ args[0], result.stderr });
        return error.DockerFailed;
    }
    return result.stdout;
}

/// Unpauses `container` and waits until its health check passes again,
/// for `zig build e2e` waits for every server to be healthy.
pub fn unpause(container: []const u8) !void {
    try docker(&.{ "unpause", container });
    try awaitHealthy(container);
}

/// Restarts `container` and waits until it is healthy again: a new mongod,
/// with an empty database.
pub fn restart(container: []const u8) !void {
    try docker(&.{ "restart", container });
    try awaitHealthy(container);
}

/// Waits until the health check of `container` passes, for 60 s at most.
pub fn awaitHealthy(container: []const u8) !void {
    const io = testing.io;
    const began = Io.Clock.awake.now(io);
    while (true) {
        const status = try dockerOutput(&.{ "inspect", "--format", "{{.State.Health.Status}}", container });
        defer testing.allocator.free(status);
        if (std.mem.eql(u8, std.mem.trim(u8, status, " \r\n"), "healthy")) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 60) return error.TestNeverHealthy;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

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
    _ = @import("limits.zig");
    _ = @import("script_vs_mongod.zig");
    _ = @import("Relay.zig");
    _ = @import("checks.zig");
    _ = @import("crud.zig");
    _ = @import("connect.zig");
    _ = @import("auth.zig");
    _ = @import("pool.zig");
    _ = @import("handshake_faults.zig");
}
