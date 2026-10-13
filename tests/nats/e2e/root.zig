//! End-to-end tests of zefir-nats against the servers of the repository's
//! docker-compose.yml.
//! Every scenario runs on zio with one executor and again with four, and
//! sees only `std.Io`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");

/// The servers of docker-compose.yml.
pub const servers = struct {
    pub const plain = "nats://127.0.0.1:14222";
    /// The plain server, by its container name.
    pub const plain_container = "zefir-nats-e2e-plain";
    pub const auth = "nats://127.0.0.1:14223";
    pub const tls = "nats://127.0.0.1:14224";
    pub const tls_first = "nats://127.0.0.1:14225";
    pub const cluster: []const []const u8 = &.{ "nats://127.0.0.1:14226", "nats://127.0.0.1:14227", "nats://127.0.0.1:14228" };
    /// The cluster's nodes by their container names, in the order above.
    pub const cluster_containers = [_][]const u8{ "zefir-nats-e2e-cluster-a", "zefir-nats-e2e-cluster-b", "zefir-nats-e2e-cluster-c" };
    /// A plain server that tests pause, by its container name.
    pub const stall = "nats://127.0.0.1:14229";
    pub const stall_container = "zefir-nats-e2e-stall";
    /// A plain server that tests stop and start, by its container name.
    pub const restart = "nats://127.0.0.1:14230";
    pub const restart_container = "zefir-nats-e2e-restart";
    /// A server whose user `rotating` gets a new password when a test
    /// reloads it: "first", then "second".
    pub const reload = "nats://127.0.0.1:14231";
    pub const reload_container = "zefir-nats-e2e-reload";
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

/// Unpauses `container` and waits until its health check passes again:
/// after a pause Docker reports it unhealthy until the next check, and
/// `zig build e2e` waits for every server to be healthy.
pub fn unpause(container: []const u8) !void {
    try docker(&.{ "unpause", container });
    try awaitHealthy(container);
}

/// Starts `container` again and waits until it is healthy.
pub fn start(container: []const u8) !void {
    try docker(&.{ "start", container });
    try awaitHealthy(container);
}

/// Waits until the health check of `container` passes, for 20 s at most.
pub fn awaitHealthy(container: []const u8) !void {
    const io = testing.io;
    const began = Io.Clock.awake.now(io);
    while (true) {
        const status = try dockerOutput(&.{ "inspect", "--format", "{{.State.Health.Status}}", container });
        defer testing.allocator.free(status);
        if (std.mem.eql(u8, std.mem.trim(u8, status, " \r\n"), "healthy")) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 20) return error.TestNeverHealthy;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Waits until `container` has exited, for 60 s at most.
pub fn awaitExited(container: []const u8) !void {
    const io = testing.io;
    const began = Io.Clock.awake.now(io);
    while (true) {
        const status = try dockerOutput(&.{ "inspect", "--format", "{{.State.Status}}", container });
        defer testing.allocator.free(status);
        if (std.mem.eql(u8, std.mem.trim(u8, status, " \r\n"), "exited")) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 60) return error.TestNeverExited;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Waits until cluster node `node` (0 for a, 1 for b, 2 for c) has routes
/// to both other nodes, for 20 s at most.
pub fn awaitRoutes(node: usize) !void {
    const names = [_][]const u8{ "\"remote_name\": \"a\"", "\"remote_name\": \"b\"", "\"remote_name\": \"c\"" };
    const io = testing.io;
    const began = Io.Clock.awake.now(io);
    while (true) {
        const routes = try dockerOutput(&.{ "exec", servers.cluster_containers[node], "wget", "-q", "-O", "-", "http://127.0.0.1:8222/routez" });
        defer testing.allocator.free(routes);
        var both = true;
        for (names, 0..) |name, other| {
            if (other != node and std.mem.find(u8, routes, name) == null) both = false;
        }
        if (both) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 20) return error.TestNoRoutes;
        try io.sleep(.fromMilliseconds(200), .awake);
    }
}

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
    _ = @import("messaging.zig");
    _ = @import("rpc.zig");
    _ = @import("reliability.zig");
}
