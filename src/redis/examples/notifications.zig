//! The notifications of the shop, with pub/sub: the packer publishes on a
//! channel that an order is ready, the shop publishes its offers on
//! channels of a pattern, and a listener, in a task of its own, hears what
//! it subscribed to. A message reaches only the subscribers that listen at
//! that moment: the server keeps none of them.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one

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
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));

    // The listener: a channel by its name, and channels by a pattern. It
    // has a connection of its own, and subscribe returns once the server
    // confirmed each name. It must stay where it is until its deinit,
    // which comes once the listener is done.
    var sub = try client.subscribe(io, op, .{ .channels = &.{"orders:ready"}, .patterns = &.{"offers:*"} });
    defer sub.deinit();
    app.info("Subscribed", .{ .subscribers = client.stats().subscribers });
    var heard_all: std.Io.Event = .unset;
    var listener = try io.concurrent(listen, .{ io, &sub, app, &heard_all });
    defer listener.cancel(io) catch {};

    // PUBLISH answers how many subscribers got the message.
    var delivered: u64 = 0;
    delivered += try client.run(io, op, cmd.publish("orders:ready", "order 1001 is packed"), .{});
    delivered += try client.run(io, op, cmd.publish("offers:beans", "two packs for the price of one"), .{});
    delivered += try client.run(io, op, cmd.publish("offers:cups", "a cup with every pack"), .{});
    // Nobody listens to this channel: the message goes nowhere.
    const unheard = try client.run(io, op, cmd.publish("news", "open at 8 tomorrow"), .{});

    // Once the listener heard the three, close the subscriber from here:
    // its next in the other task returns null.
    try heard_all.wait(io);
    sub.close(io);
    try listener.await(io);
    app.info("Published", .{ .delivered = delivered, .unheard = unheard, .subscribers = client.stats().subscribers });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Logs every message of `sub` until it closes, and sets `heard_all` once
/// three came. Keep such a loop quick: a subscriber that falls behind the
/// messages, the server cuts off.
fn listen(io: std.Io, sub: *redis.Subscriber, app: log.Logger, heard_all: *std.Io.Event) redis.Error!void {
    var heard: usize = 0;
    while (try sub.next(io)) |message| {
        // The message lives until the next call of next: copy what must
        // last longer.
        app.info("Heard", .{ .channel = message.channel, .pattern = message.pattern, .payload = message.payload });
        heard += 1;
        if (heard == 3) heard_all.set(io);
    }
    app.info("Subscriber closed", .{ .heard = heard });
}
