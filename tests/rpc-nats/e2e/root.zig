//! End-to-end tests of zefir-rpc-nats against the servers of the
//! repository's docker-compose.yml. Every scenario runs on zio with one
//! executor and again with four; the NATS clients, the transports and the
//! engines see only `std.Io`. A scenario runs Docker and the NATS CLI on
//! its own `std.Io`, zio's: with one executor zio runs its tasks in the
//! thread that waits for them, so a wait on another `std.Io` would stop
//! the services meanwhile.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const zio = @import("zio");
const e2e_options = @import("e2e_options");

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// Plain, no authentication.
    pub const plain = "nats://127.0.0.1:14222";
    /// The plain server, as the NATS CLI in nats-box reaches it.
    pub const plain_for_cli = "nats://plain:4222";
    /// A plain server that tests stop and start, by its container name.
    pub const restart = "nats://127.0.0.1:14230";
    pub const restart_container = "zefir-nats-e2e-restart";
    /// The permissions of the guide of rpc-nats: tests/rpc-nats/conf/acl.conf.
    pub const acl = "nats://127.0.0.1:14233";
};

/// Five seconds, as a timeout.
pub const five_seconds: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// A deadline 30 s away, for a scenario that only needs a stop.
pub fn far(io: Io) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
}

/// What a command printed; `deinit` frees it.
pub const Output = struct {
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(o: Output) void {
        testing.allocator.free(o.stdout);
        testing.allocator.free(o.stderr);
    }
};

/// Runs `docker` with `args` on `io` and fails unless it succeeds. A
/// scenario passes its own `io`: zio with one executor runs its tasks in
/// the thread that waits for docker.
pub fn docker(io: Io, args: []const []const u8) !void {
    (try dockerRun(io, args)).deinit();
}

/// Runs `docker` with `args` on `io` and returns what it printed.
pub fn dockerRun(io: Io, args: []const []const u8) !Output {
    var argv: [32][]const u8 = undefined;
    argv[0] = "docker";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, io, .{ .argv = argv[0 .. args.len + 1] });
    const output: Output = .{ .stdout = result.stdout, .stderr = result.stderr };
    if (!result.term.success()) {
        std.debug.print("docker {s} failed: {s}\n", .{ args[0], result.stderr });
        output.deinit();
        return error.DockerFailed;
    }
    return output;
}

/// Runs the NATS CLI of nats-box, `nats <args>`, in the network of the
/// servers, and returns what it printed: the body of a reply on stdout,
/// its headers on stderr.
pub fn natsCli(io: Io, args: []const []const u8) !Output {
    var argv: [24][]const u8 = undefined;
    const head = [_][]const u8{ "compose", "--file", e2e_options.compose_file, "--profile", "tools", "run", "--rm", "-T", "nats-box", "nats" };
    @memcpy(argv[0..head.len], &head);
    @memcpy(argv[head.len..][0..args.len], args);
    return dockerRun(io, argv[0 .. head.len + args.len]);
}

/// Stops `container` and waits until it has exited.
pub fn stop(io: Io, container: []const u8) !void {
    try docker(io, &.{ "stop", "--time", "2", container });
}

/// Starts `container` again and waits until it is healthy.
pub fn start(io: Io, container: []const u8) !void {
    try docker(io, &.{ "start", container });
    try awaitHealthy(io, container);
}

/// Waits until the health check of `container` passes, for 20 s at most.
pub fn awaitHealthy(io: Io, container: []const u8) !void {
    const began = Io.Clock.awake.now(io);
    while (true) {
        const status = try dockerRun(io, &.{ "inspect", "--format", "{{.State.Health.Status}}", container });
        defer status.deinit();
        if (std.mem.eql(u8, std.mem.trim(u8, status.stdout, " \r\n"), "healthy")) return;
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 20) return error.TestNeverHealthy;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Waits until `condition(context)` holds, checking every 10 ms, for 10 s
/// at most.
pub fn eventually(io: Io, context: anytype, comptime condition: fn (@TypeOf(context)) bool) !void {
    const began = Io.Clock.awake.now(io);
    while (!condition(context)) {
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() >= 10) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(10), .awake);
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

test "the NATS CLI of nats-box reaches the servers" {
    const out = try natsCli(testing.io, &.{ "-s", servers.plain_for_cli, "rtt" });
    defer out.deinit();
    try testing.expect(std.mem.find(u8, out.stdout, "nats://plain:4222") != null);
}

test {
    _ = @import("conformance.zig");
    _ = @import("cli.zig");
    _ = @import("acl.zig");
    _ = @import("outage.zig");
    _ = @import("adapter.zig");
    _ = @import("app.zig");
}
