//! The orders of the shop: their store, their service, which asks the
//! users' service whether the user exists, and the HTTP controller that
//! takes and shows them.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const log = zefir.log;
const Store = @import("Store.zig");
const users = @import("users.zig");

pub const OrdersModule = struct {
    pub const module: zefir.app.Module = .{
        // UserService, which UsersModule exports.
        .imports = &.{users.UsersModule},
        // The service comes first and takes the store: App builds the store
        // first, since a bean comes after what it takes.
        .providers = &.{ OrderService, OrdersDb },
        .controllers = &.{OrdersController},
    };
};

pub const Order = struct {
    id: u64,
    user_id: u64,
    item: []const u8,
};

/// The store of the orders: a type of its own, as UsersDb is.
pub const OrdersDb = struct {
    store: Store,

    pub fn init(gpa: std.mem.Allocator) OrdersDb {
        return .{ .store = .init(gpa) };
    }
    pub fn start(db: *OrdersDb, io: std.Io) !void {
        return db.store.start(io);
    }
    pub fn shutdown(db: *OrdersDb, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return db.store.shutdown(io, deadline);
    }
    pub fn deinit(db: *OrdersDb) void {
        db.store.deinit();
    }
};

/// A struct param: its fields are the dependencies, so init asks for them
/// by name.
pub const OrderService = struct {
    db: *OrdersDb,
    users: *users.UserService,
    logger: log.Logger,

    pub fn init(deps: struct {
        db: *OrdersDb,
        users: *users.UserService,
        logger: *const log.Logger,
    }) OrderService {
        return .{ .db = deps.db, .users = deps.users, .logger = deps.logger.scoped("orders") };
    }

    /// An order of the user `user_id`, who must exist: else
    /// `error.UserNotFound`.
    pub fn place(service: *OrderService, io: std.Io, arena: std.mem.Allocator, user_id: u64, item: []const u8) !Order {
        const user = try service.users.find(io, arena, user_id);
        const id = try service.db.store.insert(io, .{ .number = user_id, .text = item });
        service.logger.info("Order placed", .{ .id = id, .user = user.name, .item = item });
        return .{ .id = id, .user_id = user_id, .item = item };
    }

    /// The order `id`; its item lives in `arena`.
    pub fn find(service: *OrderService, io: std.Io, arena: std.mem.Allocator, id: u64) !Order {
        const record = try service.db.store.find(io, arena, id) orelse return error.OrderNotFound;
        return .{ .id = id, .user_id = record.number, .item = record.text };
    }
};

pub const OrdersController = struct {
    service: *OrderService,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/orders",
        .methods = .{
            .place = http.post("", .{}),
            .get = http.get("/{id}", .{}),
        },
    });

    pub const PlaceRequest = struct { user_id: u64, item: []const u8 };

    pub fn place(self: *OrdersController, ctx: *http.Context) !http.Json(Order) {
        const body = try ctx.json(PlaceRequest);
        return .{ .value = try self.service.place(ctx.io(), ctx.allocator(), body.user_id, body.item), .status = 201 };
    }

    pub fn get(self: *OrdersController, ctx: *http.Context) !http.Json(Order) {
        const path = try ctx.path(struct { id: u64 });
        return .{ .value = try self.service.find(ctx.io(), ctx.allocator(), path.id) };
    }
};
