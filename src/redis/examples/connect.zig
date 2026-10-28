//! Connecting, and what the client says when the start goes wrong. It
//! connects with the password of the settings; then it tries a wrong
//! password, a server that is not there, and URLs that the client refuses.
//! Last come `start` and `shutdown`, the methods that zefir.App calls:
//! `start` with a wrong password logs why it failed.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server, and the user unless it is default,
//!                        such as redis://app@127.0.0.1:6379
//!   APP_REDIS_PASSWORD   the user's password

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8,
        password: confy.Secret,
    },
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

    // The user of the URL, with the password of the settings: the client
    // authenticates every connection it opens with them, and names its
    // connections "shop" in CLIENT LIST.
    try connect(io, init.gpa, app, .{ .url = config.redis.url, .password = config.redis.password.expose(), .client_name = "shop" });
    // The same user with another password.
    try connect(io, init.gpa, app, .{ .url = config.redis.url, .password = "not-the-password" });
    // A server that is not there: nothing listens on port 1.
    try connect(io, init.gpa, app, .{ .url = "redis://127.0.0.1:1" });

    // URLs copied from elsewhere: init refuses what the client cannot do,
    // rather than skip it.
    for ([_][]const u8{
        "rediss://cache.example.com:6380",
        "redis://cache.example.com:6379/0?protocol=3",
        "redis://app@cache.example.com:6379",
    }) |url| {
        var refused: redis.Diagnostics = .{};
        var client = redis.Client.init(init.gpa, io, .{ .url = url, .diagnostics = &refused }) catch |err| {
            app.warn("Refused", .{ .reason = err, .details = refused.message() });
            continue;
        };
        client.deinit();
    }

    // What zefir.App calls. start is connect under a deadline of
    // Options.start_timeout, 10 s, and logs why it failed, as under App no
    // caller sees the diagnostics.
    var refused: redis.Client = try .init(init.gpa, io, .{ .url = config.redis.url, .password = "not-the-password" });
    defer refused.deinit();
    refused.start(io) catch |err| app.warn("Not started", .{ .reason = err });
    // shutdown is close by the deadline of App's stop.
    var client: redis.Client = try .init(init.gpa, io, .{ .url = config.redis.url, .password = config.redis.password.expose() });
    defer client.deinit();
    try client.start(io);
    app.info("Started", .{ .connections = client.stats().connections });
    try client.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }));
    app.info("Stopped", .{ .connections = client.stats().connections });
}

/// Connects a client of `options`, and logs how it went.
fn connect(io: std.Io, gpa: std.mem.Allocator, app: log.Logger, options: redis.Client.Options) !void {
    var client: redis.Client = try .init(gpa, io, options);
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
    var diagnostics: redis.Diagnostics = .{};
    client.connect(io, ctx, &diagnostics) catch |err| {
        app.warn("Cannot connect", .{ .reason = err, .outcome = redis.outcome(err), .details = diagnostics.message() });
        return;
    };
    defer client.close(io);
    app.info("Connected", .{});
}
