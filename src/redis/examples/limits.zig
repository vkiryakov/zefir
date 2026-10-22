//! A limit on the requests of the shop's API: each customer may make five
//! a minute. A Lua script counts them on the server, so that the count and
//! the end of its minute change together, however many requests come at
//! once. The client sends the script by its SHA1, and its text once when
//! the server lacks it: after the server forgot its scripts, the next call
//! goes on. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-limits` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
};

/// Counts a request in the window KEYS[1], which lasts ARGV[2] ms from its
/// first request: {1, the requests left} while no more than ARGV[1] came,
/// else {0, the milliseconds until the window ends}. Its SHA1 is computed
/// when the program compiles.
const allow: redis.Script = .init(
    \\local count = redis.call('INCR', KEYS[1])
    \\if count == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
    \\local limit = tonumber(ARGV[1])
    \\if count > limit then return {0, redis.call('PTTL', KEYS[1])} end
    \\return {1, limit - count}
);

/// The script's answer, a table of two numbers: a tuple.
const Verdict = struct { i64, i64 };

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "rate:ann", "rate:bob" }), .{});

    // Ann makes seven requests in a row: five pass.
    for (0..7) |_| try request(io, op, &client, app, "ann", "rate:ann");
    // Bob's window is his own.
    try request(io, op, &client, app, "bob", "rate:bob");
    // The server forgets its scripts, as after a restart: the next call
    // gets NOSCRIPT for the SHA1, sends the text, and goes on.
    try client.run(io, op, cmd.raw(void, .{ "SCRIPT", "FLUSH" }), .{});
    try request(io, op, &client, app, "bob", "rate:bob");
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// A request of `customer`, whose window is the key `window`: five a
/// minute.
fn request(io: std.Io, op: redis.OperationContext, client: *redis.Client, app: log.Logger, customer: []const u8, window: []const u8) !void {
    const verdict = try client.run(io, op, cmd.evalScript(Verdict, &allow, &.{window}, .{ 5, 60_000 }), .{});
    if (verdict[0] == 1) {
        app.info("Allowed", .{ .customer = customer, .left = verdict[1] });
    } else {
        app.warn("Too many requests", .{ .customer = customer, .retry_in_s = @divFloor(verdict[1] + 999, 1000) });
    }
}
