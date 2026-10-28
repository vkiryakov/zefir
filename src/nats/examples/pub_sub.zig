//! Publish and subscribe. The shop publishes an event for every order a
//! customer places; the mailer subscribes to every order event and sends
//! an email for each. Two services, two clients: each would be its own
//! program in production.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL   the server; nats://127.0.0.1:4222 by default

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

/// An order event, in JSON on the wire. A cancellation carries the id only.
const Order = struct { id: u32, customer: ?[]const u8 = null, total: ?[]const u8 = null };

const orders = [_]Order{
    .{ .id = 1001, .customer = "ada@example.com", .total = "42.50" },
    .{ .id = 1002, .customer = "alan@example.com", .total = "7.99" },
    .{ .id = 1003, .customer = "grace@example.com", .total = "120.00" },
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
    // any thread may log: the tasks of the runtime too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    // One runtime for the whole program: the clients run their tasks on it.
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    // The mailer subscribes first: NATS keeps no message for a subscriber
    // that comes later.
    var mailer: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "mailer" });
    defer mailer.deinit();
    try mailer.connect();
    // `>` matches one token or more: orders.created, orders.cancelled, ...
    const order_events = try mailer.subscribe("orders.>", .{});
    defer order_events.deinit();
    // Once flush returns, the server has the subscription.
    try mailer.flush(.{});

    var shop: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "shop" });
    defer shop.deinit();
    try shop.connect();
    const shop_log = logger.scoped("shop");
    for (orders) |order| {
        var buffer: [128]u8 = undefined;
        const event = try std.fmt.bufPrint(&buffer, "{f}", .{std.json.fmt(order, .{})});
        // The client copies the payload into its queue: `buffer` may be reused at once.
        try shop.publish("orders.created", event);
        shop_log.info("Order placed", .{ .order_id = order.id });
    }
    // Headers travel next to the payload, like HTTP headers.
    try shop.publishMessage(.{
        .subject = "orders.cancelled",
        .headers = &.{.{ .name = "Reason", .value = "out-of-stock" }},
        .payload = "{\"id\":1002}",
    });
    shop_log.info("Order cancelled", .{ .order_id = 1002 });
    // publish only queued the events; flush returns once the server has them.
    try shop.flush(.{});

    const mailer_log = logger.scoped("mailer");
    for (0..orders.len + 1) |_| {
        var msg = (try order_events.next(.{ .timeout = seconds(5) })) orelse break;
        defer msg.deinit();
        const event = try std.json.parseFromSlice(Order, init.gpa, msg.payload, .{});
        defer event.deinit();
        // The subject says what happened; a wildcard subscription gets them all.
        if (std.mem.eql(u8, msg.subject, "orders.created")) {
            mailer_log.info("Confirmation sent", .{ .order_id = event.value.id, .to = event.value.customer, .total = event.value.total });
        } else {
            mailer_log.info("Cancellation sent", .{ .order_id = event.value.id, .reason = msg.headers.get("Reason") });
        }
    }
}

fn seconds(n: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } };
}
