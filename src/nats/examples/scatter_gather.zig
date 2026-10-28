//! Scatter and gather: one request, many replies. The shop asks every
//! warehouse how many units of a product it has and adds the answers up
//! as they come. Then it asks again, but stops as soon as enough units
//! are found.
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

/// The warehouses: their stock of the product, and how long they take to
/// answer. Their answers come 300 ms apart, so they always come in this
/// order.
const Warehouse = struct { name: []const u8, units: u32, delay_ms: i64 };

const warehouses = [_]Warehouse{
    .{ .name = "berlin", .units = 12, .delay_ms = 100 },
    .{ .name = "paris", .units = 30, .delay_ms = 400 },
    .{ .name = "madrid", .units = 0, .delay_ms = 700 },
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

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    // Every warehouse is a service of its own, with its own client. They
    // subscribe without a queue group, so each of them gets every request.
    var clients: [warehouses.len]nats.Client = undefined;
    var subs: [warehouses.len]*nats.Subscription = undefined;
    var tasks: [warehouses.len]std.Io.Future(ServeError!void) = undefined;
    var started: usize = 0;
    defer for (clients[0..started], subs[0..started], tasks[0..started]) |*client, sub, *task| {
        task.cancel(io) catch {};
        sub.deinit();
        client.deinit();
    };
    for (warehouses, &clients, &subs, &tasks) |warehouse, *client, *sub, *task| {
        client.* = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = warehouse.name });
        errdefer client.deinit();
        try client.connect();
        sub.* = try client.subscribe("inventory.stock", .{});
        errdefer sub.*.deinit();
        try client.flush(.{});
        task.* = try io.concurrent(serveStock, .{ io, client, sub.*, warehouse });
        started += 1;
    }

    var shop: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "shop" });
    defer shop.deinit();
    try shop.connect();
    const shop_log = logger.scoped("shop");

    // Everyone's answer: the stream ends after three replies, or after two
    // seconds, whichever comes first.
    {
        const replies = try shop.requestMany("inventory.stock", "sku-42", .{
            .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
            .max_responses = warehouses.len,
        });
        defer replies.deinit();
        var total: u32 = 0;
        var count: u32 = 0;
        while (true) {
            var reply = (try replies.next(.{})) orelse break;
            defer reply.deinit();
            const units = try std.fmt.parseInt(u32, reply.payload, 10);
            total += units;
            count += 1;
            shop_log.info("Stock reported", .{ .warehouse = reply.headers.get("Warehouse"), .units = units });
        }
        shop_log.info("Stock counted", .{ .sku = "sku-42", .warehouses = count, .units = total });
    }

    // Enough is enough: stop at the first replies that cover 20 units. The
    // stream's deinit drops the replies that come later.
    {
        const replies = try shop.requestMany("inventory.stock", "sku-42", .{
            .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        });
        defer replies.deinit();
        var found: u32 = 0;
        while (found < 20) {
            var reply = (try replies.next(.{})) orelse break;
            defer reply.deinit();
            found += try std.fmt.parseInt(u32, reply.payload, 10);
        }
        shop_log.info("Enough stock found", .{ .needed = 20, .found = found });
    }

    // The warehouses stop: each answers what it took, then closes.
    for (clients[0..started]) |*client| try client.drain(.{});
    for (tasks[0..started]) |*task| try task.await(io);
}

const ServeError = nats.Subscription.NextError || nats.Client.RespondError || std.fmt.BufPrintError;

/// Answers every stock request with the warehouse's units, until the
/// subscription ends.
fn serveStock(io: std.Io, client: *nats.Client, requests: *nats.Subscription, warehouse: Warehouse) ServeError!void {
    while (true) {
        var request = (try requests.next(.{})) orelse return;
        defer request.deinit();
        // Looking the product up takes a while.
        try io.sleep(.fromMilliseconds(warehouse.delay_ms), .awake);
        var buffer: [16]u8 = undefined;
        try client.respondMessage(&request, .{
            .headers = &.{.{ .name = "Warehouse", .value = warehouse.name }},
            .payload = try std.fmt.bufPrint(&buffer, "{d}", .{warehouse.units}),
        });
    }
}
