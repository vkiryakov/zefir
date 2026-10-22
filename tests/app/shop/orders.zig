//! The orders of the shop: their repository and service, the HTTP
//! controller that takes them, and the rpc handler that serves them.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const rpc = zefir.rpc;
const log = zefir.log;
const mongo = zefir.mongo;
const bson = mongo.bson;
const api = @import("api.zig"); // the contract OrdersApi
const infra = @import("infra.zig");
const users = @import("users.zig");

pub const OrdersModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{ infra.InfraModule, users.UsersModule },
        // The service comes before the repository it takes: App builds the
        // repository first (the dependencies set the order in a module).
        .providers = &.{ OrderService, OrderRepository },
        .controllers = &.{OrdersController},
        .handlers = &.{OrdersHandler},
        .exports = &.{OrderService},
    };
};

pub const OrderRepository = struct {
    db: *infra.ShopDb,
    analytics: *infra.AnalyticsDb,

    /// How an order lies in the collection "orders": null `_id` makes the
    /// insert draw an ObjectId; BSON has no u64.
    const Document = struct { _id: ?bson.ObjectId = null, user_id: i64, item: []const u8 };

    /// Stores a new order; its strings live in `arena`.
    pub fn insert(repo: *OrderRepository, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, user_id: u64, item: []const u8) !api.Order {
        const doc: Document = .{ .user_id = std.math.cast(i64, user_id) orelse return error.UserIdTooLarge, .item = item };
        const inserted = try repo.db.db.collection("orders").insertOne(io, op, doc, .{ .allocator = arena });
        const id = try std.fmt.allocPrint(arena, "{f}", .{inserted.inserted_id.object_id});
        return .{ .id = id, .user_id = user_id, .item = item };
    }

    /// The order `id`, or null; its strings live in `arena`.
    pub fn find(repo: *OrderRepository, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, id: []const u8) !?api.Order {
        const key = bson.ObjectId.parseHex(id) catch return null;
        const doc = try repo.db.db.collection("orders").findOne(io, op, .{ ._id = key }, .{ .allocator = arena }) orelse return null;
        const order = try bson.decode(Document, arena, doc.raw(), .{});
        return .{ .id = id, .user_id = std.math.cast(u64, order.user_id) orelse return null, .item = order.item };
    }
};

/// A struct param: its fields are dependencies, so init asks for them by
/// name.
pub const OrderService = struct {
    repo: *OrderRepository,
    users: *users.UserService, // an export of UsersModule
    logger: log.Logger,

    pub fn init(deps: struct {
        repo: *OrderRepository,
        users: *users.UserService,
        logger: *const log.Logger,
    }) OrderService {
        return .{ .repo = deps.repo, .users = deps.users, .logger = deps.logger.scoped("orders") };
    }

    pub fn place(service: *OrderService, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, user_id: u64, item: []const u8) !api.Order {
        const order = try service.repo.insert(io, op, arena, user_id, item);
        service.logger.info("Order placed", .{ .id = order.id, .user_id = user_id });
        return order;
    }

    pub fn find(service: *OrderService, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, id: []const u8) !?api.Order {
        return service.repo.find(io, op, arena, id);
    }
};

pub const OrdersController = struct {
    service: *OrderService,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/orders",
        .methods = .{ .place = http.post("", .{}) },
    });

    pub const PlaceRequest = struct { user_id: u64, item: []const u8 };

    pub fn place(self: *OrdersController, ctx: *http.Context) !http.Json(api.Order) {
        const body = try ctx.json(PlaceRequest);
        const order = self.service.place(ctx.io(), .of(ctx.operation()), ctx.allocator(), body.user_id, body.item) catch |err| {
            self.service.logger.warn("Orders unavailable", .{ .reason = err });
            return error.Unavailable;
        };
        return .{ .value = order, .status = 201 };
    }
};

/// An rpc handler: rpc gives its label, `rpc_handler`.
pub const OrdersHandler = struct {
    service: *OrderService,

    pub const rpc_handler = rpc.implement(api.OrdersApi, .{});

    pub fn getOrder(self: *OrdersHandler, ctx: *rpc.Context, req: api.GetOrderRequest) !api.Order {
        return try self.service.find(ctx.io(), .of(ctx.operation()), ctx.allocator(), req.id) orelse error.OrderNotFound;
    }
};
