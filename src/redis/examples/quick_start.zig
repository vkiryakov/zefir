//! The quick start of the guide: the sessions, the page views and the
//! profiles of a coffee shop. It connects, signs a customer in with a
//! session that expires, counts the views of the home page with a
//! pipeline, keeps the customer's profile in a hash, and signs the
//! customer out. Each run starts afresh: it deletes its keys first.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-quick_start` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        /// Kept out of the URL, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// A customer's profile, as the hash user:<id> keeps it: a field of the
/// hash for each field of the struct. `visits` is optional, so that HSET
/// of a profile without it leaves it out, and never resets what HINCRBY
/// counted.
const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro } = .free,
    visits: ?i64 = null,
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    // The logger outlives the runtime, so it takes `init.io`, through which
    // the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the program, with an executor per CPU core: the
    // client and the tasks that call it run on its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // One client for the whole program, which any task may call. init
    // checks the options and does no I/O; connect opens the first
    // connection and says why when it cannot. From then on the client
    // stays where it is.
    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    var diagnostics: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)), &diagnostics) catch |err| {
        app.err("Cannot connect", .{ .reason = err, .details = diagnostics.message() });
        return err;
    };
    defer client.close(io);
    app.info("Connected", .{});

    try run(io, init.gpa, &client, app);

    const stats = client.stats();
    app.info("Done", .{ .connections = stats.connections, .in_use = stats.in_use });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// The application: it sees the client.
fn run(io: std.Io, gpa: std.mem.Allocator, client: *redis.Client, app: log.Logger) !void {
    // The memory of the replies, all freed at the end.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five seconds for all of it: each call has what is left of them.
    const op: redis.OperationContext = .of(within(io, .fromSeconds(5)));

    // Start afresh.
    _ = try client.run(io, op, cmd.del(&.{ "session:7f3a9c", "views:/home", "motd", "user:42" }), .{});

    // A session: its token names the customer, for half an hour.
    try client.run(io, op, cmd.set("session:7f3a9c", "42", .{ .ttl = .fromSeconds(30 * 60) }), .{});
    const user = try client.run(io, op, cmd.get([]const u8, "session:7f3a9c"), .{ .allocator = arena });
    app.info("Signed in", .{ .session = "7f3a9c", .user = user });
    switch (try client.run(io, op, cmd.ttl("session:7f3a9c"), .{})) {
        .expires_in => |left| app.info("Session expires", .{ .in_minutes = @divFloor(left.toMilliseconds() + 59_999, 60_000) }),
        .persistent, .missing => app.warn("Session without a time to live", .{}),
    }

    // The home page, viewed three times: each view counts itself, keeps
    // the counter for a day, and reads the message of the day, in one
    // exchange.
    try client.run(io, op, cmd.set("motd", "Fresh beans from Ethiopia", .{}), .{});
    for (0..3) |_| {
        const r = try client.pipeline(io, op, .{
            cmd.incr("views:/home"),
            cmd.expire("views:/home", .fromSeconds(24 * 60 * 60)),
            cmd.get([]const u8, "motd"),
        }, .{ .allocator = arena });
        app.info("Home page", .{ .views = try r[0], .ttl_set = try r[1], .motd = try r[2] });
    }

    // The profile: a hash with a field for each field of Profile.
    try client.run(io, op, cmd.hset("user:42", Profile{ .name = "Ann", .age = 30, .plan = .pro }), .{});
    const visits = try client.run(io, op, cmd.hincrby("user:42", "visits", 1), .{});
    app.info("Visit", .{ .user = 42, .visits = visits });
    const profile = (try client.run(io, op, cmd.hgetall(Profile, "user:42"), .{ .allocator = arena })) orelse
        return error.ProfileGone;
    app.info("Profile", .{ .name = profile.name, .age = profile.age, .plan = profile.plan, .visits = profile.visits });

    // Signing out ends the session.
    const deleted = try client.run(io, op, cmd.del(&.{"session:7f3a9c"}), .{});
    const gone = try client.run(io, op, cmd.get([]const u8, "session:7f3a9c"), .{ .allocator = arena });
    app.info("Signed out", .{ .deleted = deleted, .session = gone });
}
