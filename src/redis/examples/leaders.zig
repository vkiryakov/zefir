//! The best customers of the shop, in a sorted set: what each spent is
//! their score, the server keeps them in order, and the top comes in one
//! call. Then the sessions of one customer, found by walking the keys with
//! SCAN, end at once: "sign out everywhere". Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-leaders` runs it against the servers
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

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{"leaders"}), .{});

    // What each customer spent, as a member of the set and its score.
    _ = try client.run(io, op, cmd.zadd("leaders", &.{
        .{ .member = "ann", .score = 120.5 },
        .{ .member = "bob", .score = 87 },
        .{ .member = "cleo", .score = 240 },
        .{ .member = "dan", .score = 15 },
    }, .{}), .{});
    // Bob buys more: his score grows, and the set keeps its order.
    const bob = try client.run(io, op, cmd.zincrby("leaders", 42.5, "bob"), .{});
    app.info("Bob spent", .{ .total = bob });

    // The top three, the highest first, each with its score: a range read
    // into redis.Scored asks the server for the scores too.
    const top = try client.run(io, op, cmd.zrange(redis.Scored([]const u8), "leaders", 0, 2, .{ .rev = true }), .{ .allocator = arena });
    for (top, 1..) |leader, place| app.info("Top", .{ .place = place, .name = leader.member, .spent = leader.score });
    // Dan's place, from the top: ranks start at 0.
    const dan = (try client.run(io, op, cmd.zrevrank("leaders", "dan"), .{})).?;
    app.info("Dan", .{ .place = dan + 1, .of = try client.run(io, op, cmd.zcard("leaders"), .{}) });
    // The customers who spent 100 or more get a free pack.
    const generous = try client.run(io, op, cmd.zrangeByScore([]const u8, "leaders", .{ .inclusive = 100 }, .max, .{}), .{ .allocator = arena });
    app.info("Free pack", .{ .customers = generous });

    // Six sessions, three of them Ann's on her phone, laptop and tablet.
    for ([_][2][]const u8{
        .{ "session:a1", "ann" },  .{ "session:b2", "bob" }, .{ "session:a3", "ann" },
        .{ "session:c4", "cleo" }, .{ "session:a5", "ann" }, .{ "session:d6", "dan" },
    }) |session| try client.run(io, op, cmd.set(session[0], session[1], .{ .ttl = .fromSeconds(30 * 60) }), .{});

    // Ann signs out everywhere. SCAN walks the keys a page at a time, and
    // the iterator gives them one by one; a page is one call, so the
    // server never blocks on a walk of all its keys.
    var sessions = client.iterate(cmd.scan(.{ .match = "session:*", .count = 100 }), .{ .allocator = init.gpa });
    defer sessions.deinit();
    var ended: u64 = 0;
    while (try sessions.next(io, op)) |key| {
        // The key lives until the next call of next.
        const owner = try client.run(io, op, cmd.get([]const u8, key), .{ .allocator = arena }) orelse continue;
        if (std.mem.eql(u8, owner, "ann")) ended += try client.run(io, op, cmd.del(&.{key}), .{});
    }
    app.info("Ann signed out", .{ .sessions = ended });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}
