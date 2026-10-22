//! The checkout of the shop: customers buy packs of coffee while there are
//! some left. A purchase watches the stock and pays in a transaction, which
//! the server runs only if nobody changed the stock since: two customers
//! race for the last pack, first step by step, then as two tasks of a
//! service. Then the packer takes the paid orders off their queue, so that
//! none is lost: BLMOVE moves each into the list of the orders being
//! packed, which keeps it until it is packed. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-checkout` runs it against the
//! servers of the repository's docker-compose.yml.

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

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "stock:coffee", "orders:paid", "orders:packing" }), .{});

    // One pack left, and two customers at the checkout at once. Each has a
    // connection of its own, which holds the WATCH of the stock.
    try client.run(io, op, cmd.set("stock:coffee", 1, .{}), .{});
    {
        var ann = try client.acquire(io, op);
        defer ann.release(io);
        var bob = try client.acquire(io, op);
        defer bob.release(io);
        // Both watch the stock, and both see the last pack.
        app.info("Ann sees", .{ .left = try look(io, op, &ann) });
        app.info("Bob sees", .{ .left = try look(io, op, &bob) });
        // Ann pays first: nobody changed the stock since her WATCH, so the
        // server runs her transaction.
        app.info("Ann pays", .{ .bought = try pay(io, op, &ann, "ann") });
        // Bob pays next: the stock changed since his WATCH, so the server
        // runs none of his.
        app.info("Bob pays", .{ .bought = try pay(io, op, &bob, "bob") });
    }

    // The same race in a service: each customer is a task, and buy pays
    // again whenever the stock changed in between. One of the two gets the
    // pack, whichever is first.
    try client.run(io, op, cmd.set("stock:coffee", 1, .{}), .{});
    var cleo = try io.concurrent(buy, .{ io, &client, op, "cleo" });
    defer _ = cleo.cancel(io) catch false;
    var dan = try io.concurrent(buy, .{ io, &client, op, "dan" });
    defer _ = dan.cancel(io) catch false;
    const bought = @as(u8, @intFromBool(try cleo.await(io))) + @intFromBool(try dan.await(io));
    app.info("Two at once", .{ .bought = bought, .sold_out = 2 - bought });

    // The packer takes the paid orders one at a time. BLMOVE waits for one
    // and moves it into orders:packing in the same step: an order that the
    // packer took stays there until it is packed, so a packer that falls
    // over leaves it there rather than lose it. Each wait has 2 s; the
    // server gets 1.85 of them, so that an empty queue answers null before
    // the deadline.
    var done: usize = 0;
    while (try client.run(io, .of(within(io, .fromSeconds(2))), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena })) |order| {
        // The order is packed: it leaves orders:packing.
        _ = try client.run(io, op, cmd.lrem("orders:packing", 1, order), .{});
        done += 1;
    }
    app.info("Packed", .{ .orders = done, .packing = try client.run(io, op, cmd.llen("orders:packing"), .{}) });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Watches the stock on `conn`, and returns how many packs are left.
fn look(io: std.Io, op: redis.OperationContext, conn: *redis.Conn) !i64 {
    try conn.run(io, op, cmd.watch(&.{"stock:coffee"}), .{});
    return try conn.run(io, op, cmd.get(i64, "stock:coffee"), .{}) orelse 0;
}

/// Takes a pack off the stock and puts the order of `customer` on the
/// queue of paid orders, in one transaction: false when the stock changed
/// since the WATCH of `conn`, and the server ran none of it.
fn pay(io: std.Io, op: redis.OperationContext, conn: *redis.Conn, customer: []const u8) !bool {
    const done = try conn.transaction(io, op, .{
        cmd.decr("stock:coffee"),
        cmd.rpush("orders:paid", .{customer}),
    }, .{}) orelse return false;
    // Each command ran: an error of one would be in its place.
    _ = try done[0];
    _ = try done[1];
    return true;
}

/// Buys a pack for `customer`: watches the stock and pays, again whenever
/// the stock changed in between. False: sold out.
fn buy(io: std.Io, client: *redis.Client, op: redis.OperationContext, customer: []const u8) !bool {
    while (true) {
        var conn = try client.acquire(io, op);
        defer conn.release(io);
        if (try look(io, op, &conn) == 0) {
            // Nothing to buy. UNWATCH, so that release keeps the connection
            // for the pool rather than close it.
            try conn.run(io, op, cmd.unwatch(), .{});
            return false;
        }
        if (try pay(io, op, &conn, customer)) return true;
    }
}
