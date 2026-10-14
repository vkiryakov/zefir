//! Request and reply. The pricing service answers `pricing.quote`
//! requests with the price of a product. The checkout prices a cart: it
//! asks for a quote for every item, all within the deadline of the
//! checkout itself, and learns at once when no service listens.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL   the server; nats://127.0.0.1:4222 by default
//!
//! In tests/nats, `zig build example-request_reply` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
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

/// The pricing service's catalog: price in cents by product.
const catalog = [_]struct { sku: []const u8, cents: u32 }{
    .{ .sku = "coffee-beans", .cents = 1299 },
    .{ .sku = "grinder", .cents = 4900 },
    .{ .sku = "filter-papers", .cents = 399 },
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

    // The pricing service. Its subscription joins the queue group
    // `pricing`: run more instances, and each request goes to one of them.
    var pricing: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "pricing" });
    defer pricing.deinit();
    try pricing.connect();
    const quotes = try pricing.subscribe("pricing.quote", .{ .queue = "pricing" });
    defer quotes.deinit();
    try pricing.flush(.{});
    var service = try io.concurrent(servePrices, .{ &pricing, quotes, logger.scoped("pricing") });
    defer service.cancel(io) catch {};

    // The checkout.
    var checkout: nats.Client = try .init(init.gpa, io, .{ .servers = &.{config.nats.url}, .name = "checkout" });
    defer checkout.deinit();
    try checkout.connect();
    const checkout_log = logger.scoped("checkout");

    // The checkout has 500 ms in all; each quote gets what is left of it.
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromMilliseconds(500)));
    var total: u32 = 0;
    for ([_][]const u8{ "coffee-beans", "grinder", "filter-papers" }) |sku| {
        var reply = try checkout.request("pricing.quote", sku, .{ .timeout = ctx.deadline.?.toTimeout() });
        defer reply.deinit();
        const cents = try std.fmt.parseInt(u32, reply.payload, 10);
        total += cents;
        checkout_log.info("Quote received", .{ .sku = sku, .cents = cents, .currency = reply.headers.get("Currency") });
    }
    checkout_log.info("Cart priced", .{ .items = 3, .total_cents = total });

    // No one serves `shipping.quote`: the server says so at once, and the
    // request fails with NoResponders instead of waiting for its timeout.
    if (checkout.request("shipping.quote", "berlin", .{})) |reply| {
        var unexpected = reply;
        unexpected.deinit();
    } else |err| switch (err) {
        error.NoResponders => checkout_log.warn("No shipping service, shipping priced later", .{}),
        else => return err,
    }

    // The pricing service stops: its subscription ends once it has
    // answered what it took, and the client closes.
    try pricing.drain(.{});
    try service.await(io);
}

const ServeError = nats.Subscription.NextError || nats.Client.RespondError || std.fmt.BufPrintError;

/// Answers every request of `quotes` with the price of the product it
/// names, until the subscription ends.
fn servePrices(client: *nats.Client, quotes: *nats.Subscription, pricing_log: log.Logger) ServeError!void {
    while (true) {
        var request = (try quotes.next(.{})) orelse return;
        defer request.deinit();
        const cents = for (catalog) |item| {
            if (std.mem.eql(u8, item.sku, request.payload)) break item.cents;
        } else {
            pricing_log.warn("Unknown product", .{ .sku = request.payload });
            try client.respondMessage(&request, .{ .headers = &.{.{ .name = "Error", .value = "unknown-sku" }} });
            continue;
        };
        var buffer: [16]u8 = undefined;
        // The reply goes to the request's reply subject, the requester's inbox.
        try client.respondMessage(&request, .{
            .headers = &.{.{ .name = "Currency", .value = "EUR" }},
            .payload = try std.fmt.bufPrint(&buffer, "{d}", .{cents}),
        });
        pricing_log.info("Quote sent", .{ .sku = request.payload, .cents = cents });
    }
}
