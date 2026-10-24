//! The orders of the shop, in the collection "orders": the operations
//! that write documents and read them back. It takes orders in, finds a
//! customer's, ships them, looks one up by its number, takes a phone
//! order if it is not in yet, replaces one, raises one and shows it as it
//! is now, takes one back, and drops the cancelled ones. Each run starts
//! from an empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-orders` runs it against the servers
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

const Status = enum { placed, shipped, cancelled };

/// An order, under the number the shop gives it: the `_id` is the shop's,
/// so no insert makes one.
const Order = struct {
    _id: i32,
    customer: []const u8,
    item: []const u8,
    amount: i32,
    status: Status = .placed,
};

/// What a customer sees of an order: a projection of it.
const Line = struct {
    _id: i32,
    item: []const u8,
    amount: i32,
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

    // insertMany: the orders of the day, with the shop's own numbers.
    const day = [_]Order{
        .{ ._id = 1, .customer = "ann", .item = "coffee beans", .amount = 18 },
        .{ ._id = 2, .customer = "bob", .item = "grinder", .amount = 95 },
        .{ ._id = 3, .customer = "ann", .item = "kettle", .amount = 40 },
        .{ ._id = 4, .customer = "cleo", .item = "mugs", .amount = 24 },
        .{ ._id = 5, .customer = "ann", .item = "filters", .amount = 6 },
        .{ ._id = 6, .customer = "bob", .item = "scale", .amount = 31, .status = .cancelled },
    };
    const taken = try orders.insertMany(io, op, &day, .{ .allocator = arena });
    app.info("Orders taken", .{ .inserted = taken.inserted });

    // find: Ann's open orders, the dearest first, two in a batch; only the
    // fields she sees.
    var anns = try orders.find(io, op, .{ .customer = "ann", .status = .placed }, .{
        .allocator = arena,
        .sort = bson.literal(.{ .amount = -1 }),
        .projection = bson.literal(.{ .item = 1, .amount = 1 }),
        .batch_size = 2,
    });
    defer anns.deinit(io);
    while (try anns.next(io, op)) |doc| {
        const line = try bson.decode(Line, arena, doc, .{});
        app.info("Ann's order", .{ .number = line._id, .item = line.item, .amount = line.amount });
    }

    // updateMany: everything Ann ordered goes out today.
    const shipped = try orders.updateMany(io, op, .{ .customer = "ann", .status = .placed }, .{ .@"$set" = .{ .status = .shipped } }, .{ .allocator = arena });
    app.info("Shipped", .{ .matched = shipped.matched, .modified = shipped.modified });

    // findOne: an order by its number.
    if (try orders.findOne(io, op, .{ ._id = 2 }, .{ .allocator = arena })) |doc| {
        const order = try bson.decode(Order, arena, doc.raw(), .{});
        app.info("Order 2", .{ .customer = order.customer, .item = order.item, .status = order.status });
    }

    // updateOne with upsert: a phone order, taken twice by mistake; the
    // second time it is there already, and nothing changes.
    for (0..2) |_| {
        const phone = try orders.updateOne(io, op, .{ ._id = 7 }, .{ .@"$setOnInsert" = .{ .customer = "dan", .item = "tea", .amount = 12, .status = .placed } }, .{ .allocator = arena, .upsert = true });
        if (phone.upserted_id) |id| {
            app.info("Phone order taken", .{ .number = try id.asI64() });
        } else app.info("Phone order there already", .{ .matched = phone.matched, .modified = phone.modified });
    }

    // replaceOne: Bob takes another grinder; the order keeps its number.
    const replaced = try orders.replaceOne(io, op, .{ ._id = 2 }, .{ .customer = "bob", .item = "hand grinder", .amount = 60, .status = .placed }, .{ .allocator = arena });
    app.info("Order 2 replaced", .{ .matched = replaced.matched, .modified = replaced.modified });

    // findOneAndUpdate: Cleo takes two more mugs, and the shop shows her
    // the order as it is after the change.
    const raised = try orders.findOneAndUpdate(io, op, .{ ._id = 4 }, .{ .@"$inc" = .{ .amount = 12 } }, .{ .allocator = arena, .return_document = .after }) orelse
        return error.OrderNotFound;
    const mugs = try bson.decode(Order, arena, raised.raw(), .{});
    app.info("Order 4 now", .{ .item = mugs.item, .amount = mugs.amount });

    // findOneAndDelete: Dan calls back; his order goes, and the shop sees
    // what it was.
    const dropped = try orders.findOneAndDelete(io, op, .{ .customer = "dan" }, .{ .allocator = arena }) orelse
        return error.OrderNotFound;
    const tea = try bson.decode(Order, arena, dropped.raw(), .{});
    app.info("Order taken back", .{ .number = tea._id, .item = tea.item });

    // deleteMany: the cancelled orders go at the end of the day.
    const cleared = try orders.deleteMany(io, op, .{ .status = .cancelled }, .{ .allocator = arena });
    app.info("Cancelled orders cleared", .{ .deleted = cleared.deleted });
    app.info("Orders left", .{ .count = try orders.countDocuments(io, op, .{}, .{ .allocator = arena }) });
}
