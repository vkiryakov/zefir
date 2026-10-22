//! The shop of the design of zefir.App, shop/, against real servers: the
//! NATS server `plain` and the mongod server `mongo-plain` of the
//! repository's docker-compose.yml, which `zig build up` starts. The test
//! starts the shop on a free port, waits until it is ready, places an order
//! over HTTP, reads it back over rpc through NATS with a client of its own,
//! as another service would, stops the shop with SIGTERM and checks the
//! order of the stop in its log. The build gives the path of the shop's
//! program (`shop_options`). Windows cannot send SIGTERM to one process:
//! there the test is skipped.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const zefir = @import("zefir");
const options = @import("shop_options");
const client = @import("e2e/client.zig");
const Program = @import("e2e/child.zig").Program;
const api = @import("shop/api.zig");

const Io = std.Io;
const testing = std.testing;

const nats_url = "nats://127.0.0.1:14222";
const mongo_uri = "mongodb://127.0.0.1:27117";

test "the shop: an order over HTTP, read back over rpc through NATS, then SIGTERM" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var dog = try io.concurrent(watch, .{io});
    defer dog.cancel(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const port = try client.freePort(io);
    var digits: [5]u8 = undefined;
    var shop: Program = try .start(io, options.shop, &.{
        .{ "SHOP_PORT", try std.fmt.bufPrint(&digits, "{d}", .{port}) },
        .{ "SHOP_MONGO_URI", mongo_uri },
        .{ "SHOP_NATS_URL", nats_url },
    }, .stdout);
    defer shop.deinit(io);
    // Ready: the clients connected, the server listens and the rpc server
    // has subscribed.
    try waitReady(io, arena, port);

    // An order over HTTP, stored in Mongo.
    const placed = try client.fetch(io, testing.allocator, arena, port, "/api/v1/orders", "{\"user_id\":7,\"item\":\"Green tea\"}");
    if (placed.status != 201) {
        std.debug.print("POST /api/v1/orders: {d} {s}\n", .{ placed.status, placed.body });
        return error.TestNotCreated;
    }
    const order = try std.json.parseFromSliceLeaky(api.Order, arena, placed.body, .{});
    try testing.expectEqual(7, order.user_id);
    try testing.expectEqualStrings("Green tea", order.item);

    // The same order over rpc through NATS, from a client with a connection
    // of its own.
    var nc: zefir.nats.Client = try .init(testing.allocator, io, .{ .servers = &.{nats_url}, .name = "shop-test" });
    defer nc.deinit();
    try nc.connect();
    defer nc.close();
    var bus: zefir.rpc_nats.Transport = try .init(testing.allocator, &nc, .{});
    defer bus.deinit(io);
    var orders: zefir.rpc.Client = try .init(testing.allocator, .{}, .{ .transport = bus.clientTransport() });
    defer orders.deinit();
    var found = try orders.call(io, .root, api.OrdersApi.getOrder, .{ .id = order.id }, .{});
    defer found.deinit();
    switch (found.outcome) {
        .ok => |got| {
            try testing.expectEqualStrings(order.id, got.id);
            try testing.expectEqual(7, got.user_id);
            try testing.expectEqualStrings("Green tea", got.item);
        },
        .failure => |failure| {
            std.debug.print("getOrder failed: {t} {s}\n", .{ failure.code, failure.message });
            return error.TestCallFailed;
        },
    }

    // SIGTERM: the servers stop first, the last built first, then the
    // clients they used.
    const term = try shop.stop(io, .TERM);
    if (term != .exited or term.exited != 0) {
        std.debug.print("the shop {f}; its log:\n{s}\n", .{ term, shop.log.items });
        return error.TestUnexpectedExit;
    }
    try shop.expectInOrder(&.{
        "[zefir_app] AppModule.Servers.rpcServer stopped",
        "[zefir_app] AppModule.Servers.httpServer stopped",
        "[zefir_app] InfraModule.Nats.natsClient stopped",
        "[zefir_app] InfraModule.Mongo.mongoClient stopped",
        "[zefir_app] stopped",
    });
}

/// Asks `GET /api/readyz` until it answers 200, 10 s at most: the shop
/// starts, connects to Mongo and NATS, and then listens.
fn waitReady(io: Io, arena: std.mem.Allocator, port: u16) !void {
    const start = Io.Clock.awake.now(io);
    while (true) {
        if (client.fetch(io, testing.allocator, arena, port, "/api/readyz", null)) |res| {
            if (res.status == 200) return;
        } else |_| {}
        if (start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > 10_000) return error.TestShopNotReady;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}

/// The run has a minute: past it, it is stuck.
fn watch(io: Io) void {
    io.sleep(.fromSeconds(60), .awake) catch return;
    std.debug.print("the test of the shop still runs after 60 s: a hang\n", .{});
    std.process.exit(4);
}
