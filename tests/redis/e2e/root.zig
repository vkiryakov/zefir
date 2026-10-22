//! End-to-end tests of zefir-redis against the Redis and Valkey servers
//! of the repository's docker-compose.yml, profile `redis`, on the image
//! that REDIS_IMAGE names. Every scenario runs on zio with one executor
//! and again with four, under a time limit, and sees only `std.Io`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const zio = @import("zio");

/// The context of a call that must end within `duration` from now.
pub fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// A client of redis-plain, with an arena for the replies. A call that
/// fails prints its error and diagnostics.
pub const Session = struct {
    io: Io,
    client: redis.Client,
    arena: std.heap.ArenaAllocator,

    pub fn open(s: *Session, io: Io) !void {
        s.* = .{ .io = io, .client = try .init(testing.allocator, io, .{ .url = "redis://127.0.0.1:16379" }), .arena = .init(testing.allocator) };
        errdefer s.close();
        var d: redis.Diagnostics = .{};
        s.client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
            std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
            return err;
        };
    }

    pub fn close(s: *Session) void {
        s.client.deinit();
        s.arena.deinit();
    }

    pub fn run(s: *Session, command: anytype) !redis.Client.ReplyOf(@TypeOf(command)) {
        return s.runIn(within(s.io, .fromSeconds(10)), command);
    }

    pub fn runIn(s: *Session, op: redis.OperationContext, command: anytype) !redis.Client.ReplyOf(@TypeOf(command)) {
        var d: redis.Diagnostics = .{};
        return s.client.run(s.io, op, command, .{ .allocator = s.arena.allocator(), .diagnostics = &d }) catch |err| {
            std.debug.print("{s}: {t}: {s}\n", .{ command.name(), err, d.message() });
            return err;
        };
    }
};

/// The number after `prefix` in the text of INFO; null when it lacks it.
pub fn infoNumber(text: []const u8, comptime prefix: []const u8) ?u64 {
    const at = std.mem.find(u8, text, prefix) orelse return null;
    const from = at + prefix.len;
    var end = from;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[from..end], 10) catch null;
}

/// The servers of docker-compose.yml.
pub const servers = struct {
    /// redis-plain: no password, DEBUG on.
    pub const plain_port: u16 = 16379;
    /// redis-auth: the users of conf/users.acl, each with the password
    /// `<name>-pass`.
    pub const auth_port: u16 = 16380;
    /// redis-stall: no password; the tests pause it by its container name,
    /// so that it stops answering.
    pub const stall_port: u16 = 16381;
    pub const stall_container = "zefir-redis-e2e-stall";
    /// redis-restart: no password; the tests restart it by its container
    /// name.
    pub const restart_port: u16 = 16382;
    pub const restart_container = "zefir-redis-e2e-restart";
    /// redis-cluster: cluster mode, which the client refuses.
    pub const cluster_port: u16 = 16383;
    /// redis-old: Redis 6.2.24, which the client refuses.
    pub const old_port: u16 = 16384;
};

// The helpers of docker below run it on std's test `Io`, whatever runtime
// the test is on, and hold the thread that calls them until docker
// returns. Called from a task of zio, they hold its executor: with one
// executor, no other task of the runtime runs meanwhile, for the seconds
// of a `docker restart` among them, so a call out sees the restart only
// once it is over.

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

/// Restarts `container` and waits until it is healthy again: a new server,
/// with an empty database.
pub fn restart(container: []const u8) !void {
    try docker(&.{ "restart", container });
    try awaitHealthy(container);
}

/// Starts `container`, which a test stopped, and waits until it is healthy
/// again.
pub fn start(container: []const u8) !void {
    try docker(&.{ "start", container });
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
    _ = @import("handshake.zig");
    _ = @import("auth.zig");
    _ = @import("pool.zig");
    _ = @import("pipeline.zig");
    _ = @import("transactions.zig");
    _ = @import("commands.zig");
    _ = @import("scripts.zig");
    _ = @import("streams.zig");
    _ = @import("pubsub.zig");
}
