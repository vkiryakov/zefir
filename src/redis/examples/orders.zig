//! The shipping of the shop's orders, through a stream: the shop adds an
//! entry to the stream "shipping" for each order to ship, and the couriers
//! of the group "couriers" take them, each entry to one courier, and
//! acknowledge each once it is delivered. A courier that falls over leaves
//! the entries it took pending, and another claims them. Each run starts
//! afresh.
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

/// An order to ship, as an entry of the stream keeps it: a field for each
/// field of the struct.
const Shipment = struct {
    order: u64,
    address: []const u8,
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
    _ = try client.run(io, op, cmd.del(&.{"shipping"}), .{});

    // The group of the couriers, made as the service starts; a group that
    // is there already, from the start before, is fine.
    try createGroup(io, op, &client);
    try createGroup(io, op, &client);

    // Three orders to ship. The server gives each entry its id: the time
    // in milliseconds and a sequence number.
    for ([_]Shipment{
        .{ .order = 1001, .address = "12 Bean Street" },
        .{ .order = 1002, .address = "7 Roast Lane" },
        .{ .order = 1003, .address = "3 Crema Court" },
    }) |shipment| {
        const id = try client.run(io, op, cmd.xadd("shipping", shipment, .{ .max_len = 10_000 }), .{});
        app.info("To ship", .{ .order = shipment.order, .id = id });
    }

    // Kim takes two orders: the group gives them to her alone.
    const kim = try client.run(io, op, cmd.xreadgroup(Shipment, "shipping", .{ .group = "couriers", .consumer = "kim", .count = 2 }), .{ .allocator = arena });
    for (kim) |entry| app.info("Kim takes", .{ .order = entry.fields.?.order });
    // She delivers the first, and acknowledges it: it is done.
    _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{kim[0].id}), .{});
    app.info("Kim delivers", .{ .order = kim[0].fields.?.order });
    // Then she falls over, with the second still hers: pending.

    // Lee takes what nobody has taken yet, and delivers it.
    const lee = try client.run(io, op, cmd.xreadgroup(Shipment, "shipping", .{ .group = "couriers", .consumer = "lee" }), .{ .allocator = arena });
    for (lee) |entry| {
        app.info("Lee takes", .{ .order = entry.fields.?.order });
        _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{entry.id}), .{});
    }

    // What the group gave out and nobody acknowledged.
    const pending = try client.run(io, op, cmd.xpending("shipping", "couriers"), .{ .allocator = arena });
    for (pending.consumers) |consumer| app.info("Pending", .{ .consumer = consumer.name, .entries = consumer.count });

    // Lee claims the entries that have been pending for long: in a service,
    // minutes; here, 100 ms.
    try io.sleep(.fromMilliseconds(200), .awake);
    const claimed = try client.run(io, op, cmd.xautoclaim(Shipment, "shipping", .{ .group = "couriers", .consumer = "lee", .min_idle = .fromMilliseconds(100) }), .{ .allocator = arena });
    for (claimed.entries) |entry| {
        app.info("Lee claims", .{ .order = entry.fields.?.order });
        _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{entry.id}), .{});
    }
    const left = try client.run(io, op, cmd.xpending("shipping", "couriers"), .{ .allocator = arena });
    app.info("Pending now", .{ .entries = left.count });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Makes the group "couriers" of the stream "shipping", and the stream if
/// it is not there; a group that is there already is no error.
fn createGroup(io: std.Io, op: redis.OperationContext, client: *redis.Client) !void {
    var d: redis.Diagnostics = .{};
    client.run(io, op, cmd.xgroupCreate("shipping", "couriers", .{ .mkstream = true }), .{ .diagnostics = &d }) catch |err| {
        if (err == error.ServerError and d.isCode("BUSYGROUP")) return;
        return err;
    };
}
