//! A whole service on zio: the order service of a shop. One zio runtime
//! runs everything on all CPU cores; one NATS client serves every task of
//! the service: one takes orders, one logs what happens to the
//! connection. The demo plays the customers too: a task places an order
//! every 200 ms.
//!
//! The service runs until Ctrl+C or SIGTERM, then drains: it answers the
//! orders it took, and closes. A server restart does not stop it: the
//! client reconnects and subscribes again, and the customers' orders go
//! through once it is back.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL      the server; nats://127.0.0.1:4222 by default
//!   APP_RUN_SECONDS   stop after this many seconds, as if Ctrl+C came
//!
//! In tests/nats, `zig build example-zio_app` runs it against the servers
//! of the repository's docker-compose.yml.

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
    run_seconds: ?u32 = null,
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

    // One runtime for the application, with an executor per CPU core. The
    // parts of the service take its `io`: the client and the tasks.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();
    const app_log = logger.scoped("app");

    // One client for the whole service: every method may be called from
    // any task at once. It must not move once connected.
    var client: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "order-service" });
    defer client.deinit();
    try client.connect();
    app_log.info("Started", .{ .server = client.connectedServer() });

    var events = try io.concurrent(logEvents, .{ &client, logger.scoped("events") });
    defer events.cancel(io) catch {};

    // Every instance of the service joins the queue group: start three,
    // and each order goes to one of them.
    const orders = try client.subscribe("orders.place", .{ .queue = "order-service" });
    defer orders.deinit();
    try client.flush(.{});
    var service = try io.concurrent(takeOrders, .{ &client, orders, logger.scoped("orders") });
    defer service.cancel(io) catch {};

    var customers = try io.concurrent(placeOrders, .{ io, &client, logger.scoped("customers") });
    defer customers.cancel(io) catch {};

    // Until Ctrl+C, SIGTERM, or the run time is over.
    var stop: std.Io.Event = .unset;
    var on_interrupt = try io.concurrent(stopOnSignal, .{ io, &stop, .interrupt });
    defer on_interrupt.cancel(io) catch {};
    var on_terminate = try io.concurrent(stopOnSignal, .{ io, &stop, .terminate });
    defer on_terminate.cancel(io) catch {};
    var timer: ?std.Io.Future(std.Io.Cancelable!void) = if (config.run_seconds) |seconds|
        try io.concurrent(stopAfter, .{ io, &stop, seconds })
    else
        null;
    defer if (timer) |*t| t.cancel(io) catch {};
    try stop.wait(io);

    app_log.info("Stopping", .{});
    // No new orders; then the service answers the ones it took and closes.
    customers.cancel(io) catch {};
    try client.drain(.{});
    try service.await(io);
    try events.await(io);
    const stats = client.stats();
    app_log.info("Stopped", .{ .messages_in = stats.messages_in, .messages_out = stats.messages_out, .reconnects = stats.reconnects });
}

const TakeError = nats.Subscription.NextError || nats.Client.PublishError || nats.Client.RespondError || std.fmt.BufPrintError;

/// The order service: confirms every order, and publishes an
/// `orders.created` event for the rest of the shop.
fn takeOrders(client: *nats.Client, orders: *nats.Subscription, orders_log: log.Logger) TakeError!void {
    var next_id: u32 = 1;
    while (true) {
        var order = (try orders.next(.{})) orelse return;
        defer order.deinit();
        const id = next_id;
        next_id += 1;
        var buffer: [64]u8 = undefined;
        const event = try std.fmt.bufPrint(&buffer, "{{\"id\":{d},\"cart\":\"{s}\"}}", .{ id, order.payload });
        try client.publish("orders.created", event);
        try client.respond(&order, try std.fmt.bufPrint(&buffer, "{d}", .{id}));
        orders_log.info("Order taken", .{ .order_id = id, .cart = order.payload });
    }
}

const PlaceError = nats.Client.RequestError || std.Io.Cancelable;

/// The customers of the demo: an order every 200 ms. A lost connection
/// fails the orders waiting at that moment; the next ones go through once
/// the client is back.
fn placeOrders(io: std.Io, client: *nats.Client, customers_log: log.Logger) PlaceError!void {
    while (true) {
        try io.sleep(.fromMilliseconds(200), .awake);
        var confirmation = client.request("orders.place", "coffee-beans,grinder", .{}) catch |err| switch (err) {
            // Restarting, or no instance of the service up yet: try again later.
            error.Disconnected, error.Timeout, error.NoResponders, error.BufferFull => {
                customers_log.warn("Order failed", .{ .reason = err });
                continue;
            },
            else => |e| return e,
        };
        defer confirmation.deinit();
        customers_log.info("Order confirmed", .{ .order_id = confirmation.payload });
    }
}

/// Logs what happens to the connection, until the client has closed.
fn logEvents(client: *nats.Client, events_log: log.Logger) nats.Client.NextEventError!void {
    while (try client.nextEvent(.{})) |event| switch (event) {
        .connected => |server| events_log.info("Connected", .{ .server = server }),
        .disconnected => |lost| events_log.warn("Disconnected", .{ .server = lost.server, .reason = lost.reason }),
        .reconnecting => |attempt| events_log.info("Reconnecting", .{ .server = attempt.server, .attempt = attempt.attempt }),
        .reconnected => |server| events_log.info("Reconnected", .{ .server = server }),
        .closed => |reason| events_log.info("Closed", .{ .reason = reason }),
        else => events_log.info("Event", .{ .kind = std.meta.activeTag(event) }),
    };
}

fn stopOnSignal(io: std.Io, stop: *std.Io.Event, kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    defer signal.deinit();
    try signal.wait();
    stop.set(io);
}

fn stopAfter(io: std.Io, stop: *std.Io.Event, seconds: u32) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(seconds), .awake);
    stop.set(io);
}
