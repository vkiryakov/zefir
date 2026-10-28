//! Durable writes: the shop takes an order and the payment for it, and a
//! crash of mongod must lose neither. The order goes in with `journal`:
//! mongod answers once it is in its journal on disk. The payment asks for
//! a majority of the servers too; a standalone mongod is a majority of
//! one. Each run starts from an empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-durable` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const zio = @import("zio");
const bson = @import("mongo-bson");

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        password: ?confy.Secret = null,
    } = .{},
};

const Status = enum { placed, paid };

/// An order, under the number the shop gives it.
const Order = struct {
    _id: i32,
    customer: []const u8,
    amount: i32,
    status: Status = .placed,
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

    var client: mongo.Client = try .init(init.gpa, io, .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
    try client.connect(io, ctx, null);
    defer client.close(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(&client, "shop", &ids);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: mongo.OperationContext = .of(ctx);
    const orders = db.collection("orders");
    try orders.drop(io, op, .{ .allocator = arena });

    // The order: mongod answers once it is in the journal on disk, so a
    // crash after this call cannot lose it.
    const placed = try orders.insertOne(io, op, Order{ ._id = 1, .customer = "ann", .amount = 18 }, .{
        .allocator = arena,
        .write_concern = .{ .journal = true },
    });
    app.info("Order placed", .{ .number = try placed.inserted_id.asI64() });

    // The payment: a placed order becomes paid, acknowledged by a majority
    // of the servers, each with it in its journal. The filter takes only a
    // placed order, so a payment sent again changes nothing.
    const paid = try orders.findOneAndUpdate(io, op, .{ ._id = 1, .status = .placed }, .{ .@"$set" = .{ .status = .paid } }, .{
        .allocator = arena,
        .return_document = .after,
        .write_concern = .{ .w = .majority, .journal = true },
    }) orelse return error.OrderNotFound;
    const order = try bson.decode(Order, arena, paid.raw(), .{});
    app.info("Order paid", .{ .number = order._id, .customer = order.customer, .amount = order.amount, .status = order.status });
}
