//! Queue groups. Three workers share the orders: the server hands each
//! order to one member of the group `order-workers`, so every order is
//! handled once, and more workers handle more orders. At the end the
//! workers drain: they finish the orders they took, then stop.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL   the server; nats://127.0.0.1:4222 by default
//!
//! In tests/nats, `zig build example-queue_group` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const nats = @import("nats");
const zio = @import("zio");

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
};

const worker_count = 3;
const order_count = 9;

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });

    // The logger outlives the runtime, so it takes `init.io`, through which
    // any thread may log: the tasks of the runtime too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    // Four executors: the workers really run at the same time.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    // The workers' client. Here the three workers share it; in production
    // each is usually a process of its own, and the group works the same.
    var workers: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "order-workers" });
    defer workers.deinit();
    try workers.connect();

    var subs: [worker_count]*nats.Subscription = undefined;
    var subscribed: usize = 0;
    defer for (subs[0..subscribed]) |sub| sub.deinit();
    for (&subs) |*sub| {
        // Same subject, same queue group: each order goes to one of them.
        sub.* = try workers.subscribe("orders.created", .{ .queue = "order-workers" });
        subscribed += 1;
    }
    try workers.flush(.{});

    const worker_log = logger.scoped("worker");
    var tasks: [worker_count]std.Io.Future(nats.Subscription.NextError!u32) = undefined;
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| {
        _ = task.cancel(io) catch 0;
    };
    for (subs, 1..) |sub, number| {
        tasks[started] = try io.concurrent(work, .{ io, worker_log, sub, number });
        started += 1;
    }

    // The shop, another service, places the orders.
    var shop: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "shop" });
    defer shop.deinit();
    try shop.connect();
    for (1..order_count + 1) |id| {
        var buffer: [16]u8 = undefined;
        try shop.publish("orders.created", try std.fmt.bufPrint(&buffer, "{d}", .{id}));
    }
    // Once the server has the orders, they are on their way to the workers.
    try shop.flush(.{});

    // The workers stop taking orders, finish the ones they have, and the
    // client closes; each `next()` then returns null.
    try workers.drain(.{});
    var total: u32 = 0;
    for (tasks[0..started]) |*task| total += try task.await(io);
    logger.scoped("shop").info("All orders handled", .{ .orders = total });
}

/// One worker: handles orders until its subscription ends. Returns how
/// many it handled.
fn work(io: std.Io, worker_log: log.Logger, sub: *nats.Subscription, number: usize) nats.Subscription.NextError!u32 {
    var handled: u32 = 0;
    while (true) {
        var order = (try sub.next(.{})) orelse break;
        defer order.deinit();
        // The work an order takes.
        try io.sleep(.fromMilliseconds(20), .awake);
        handled += 1;
        worker_log.info("Order handled", .{ .worker = number, .order_id = order.payload });
    }
    worker_log.info("Worker done", .{ .worker = number, .orders = handled });
    return handled;
}
