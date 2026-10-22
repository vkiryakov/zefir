//! The reports of the shop over its orders: the operations that compute
//! from documents, and those of indexes and collections. It sums each
//! customer's spending, counts orders two ways, lists the customers once
//! each, makes an index for the reports and lists it, and makes a capped
//! collection with a command of the server. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-reports` runs it against the servers
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

const Order = struct {
    _id: i32,
    customer: []const u8,
    amount: i32,
    status: enum { placed, shipped, cancelled },
};

/// A row of the report: what `$group` makes of a customer's orders.
const Spending = struct {
    _id: []const u8,
    total: i32,
    orders: i32,
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
    const week = [_]Order{
        .{ ._id = 1, .customer = "ann", .amount = 18, .status = .shipped },
        .{ ._id = 2, .customer = "bob", .amount = 95, .status = .shipped },
        .{ ._id = 3, .customer = "ann", .amount = 40, .status = .shipped },
        .{ ._id = 4, .customer = "cleo", .amount = 24, .status = .placed },
        .{ ._id = 5, .customer = "bob", .amount = 31, .status = .cancelled },
        .{ ._id = 6, .customer = "ann", .amount = 6, .status = .placed },
    };
    _ = try orders.insertMany(io, op, &week, .{ .allocator = arena });

    // aggregate: what each customer spent, but for cancelled orders, by
    // name. The pipeline is a tuple of stages.
    var spending = try orders.aggregate(io, op, .{
        .{ .@"$match" = .{ .status = .{ .@"$ne" = "cancelled" } } },
        .{ .@"$group" = .{ ._id = "$customer", .total = .{ .@"$sum" = "$amount" }, .orders = .{ .@"$sum" = 1 } } },
        .{ .@"$sort" = .{ ._id = 1 } },
    }, .{ .allocator = arena });
    defer spending.deinit(io);
    while (try spending.next(io, op)) |doc| {
        const row = try bson.decode(Spending, arena, doc, .{});
        app.info("Spent", .{ .customer = row._id, .total = row.total, .orders = row.orders });
    }

    // countDocuments counts the matching documents one by one;
    // estimatedDocumentCount reads the size the collection keeps.
    const open = try orders.countDocuments(io, op, .{ .status = .placed }, .{ .allocator = arena });
    const all = try orders.estimatedDocumentCount(io, op, .{ .allocator = arena });
    app.info("Counted", .{ .open = open, .all = all });

    // distinct: each customer once. The values come in a BSON array.
    const customers = try orders.distinct(io, op, "customer", .{}, .{ .allocator = arena });
    var names = customers.raw().iterator();
    while (try names.next()) |element| app.info("Customer", .{ .name = element.value.string });

    // An index for the reports: by customer, the dearest orders first. Its
    // name comes from its keys.
    const made = try orders.createIndexes(io, op, &.{.{ .keys = bson.literal(.{ .customer = 1, .amount = -1 }) }}, .{ .allocator = arena });
    app.info("Index made", .{ .name = made[0] });
    var indexes = try orders.listIndexes(io, op, .{ .allocator = arena });
    defer indexes.deinit(io);
    while (try indexes.next(io, op)) |index| app.info("Index", .{ .name = (try index.get("name")).?.string });
    try orders.dropIndex(io, op, made[0], .{ .allocator = arena });

    // runCommand: any command of the server, such as create, which the
    // collection API has no operation for. A capped collection keeps the
    // newest documents only, within its size.
    const audit = db.collection("audit");
    try audit.drop(io, op, .{ .allocator = arena });
    const created = try db.runCommand(io, op, .{ .create = "audit", .capped = true, .size = 4096 }, .{ .allocator = arena });
    app.info("Collection made", .{ .name = "audit", .ok = try (try created.raw().get("ok")).?.asF64() });
    // listCollections: the collections of the database, here only "audit".
    var found = try db.listCollections(io, op, .{ .allocator = arena, .filter = bson.literal(.{ .name = "audit" }) });
    defer found.deinit(io);
    while (try found.next(io, op)) |info| {
        app.info("Collection", .{ .name = (try info.get("name")).?.string, .capped = (try info.getPath("options.capped")).?.boolean });
    }
    try audit.drop(io, op, .{ .allocator = arena });
}
