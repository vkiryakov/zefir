//! The orders service, whose handler calls the users service: a service
//! that is a server and a client at once. Both services run in this one
//! program, each on a memory transport of its own, as they would on two
//! hosts.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const users_api = @import("users-api");
const orders_api = @import("orders-api");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

const Config = struct {
    users: struct {
        /// The longest a call to the users service may take; a caller with
        /// less time left gives the call less.
        timeout_ms: u32 = 500,
    } = .{},
};

/// Middleware of the client of users: once the users service could not
/// take a call, the breaker opens, and later calls fail at once with
/// `error.Unavailable`, without going out. A real one closes again after a
/// pause, and shares its state with the other replicas through a store.
const CircuitBreaker = struct {
    logger: log.Logger,
    /// Shared by every call at once, like every object of middleware.
    open: std.atomic.Value(bool) = .init(false),

    pub fn run(self: *CircuitBreaker, ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void {
        if (self.open.load(.acquire)) {
            self.logger.info("Call not sent", .{ .method = ctx.route().method });
            // Unavailable: the caller knows that the call did not run.
            return error.Unavailable;
        }
        next.run() catch |err| {
            if (err == error.Unavailable and !self.open.swap(true, .acq_rel)) {
                self.logger.warn("Breaker opened", .{ .service = ctx.route().service });
            }
            return err;
        };
    }
};

/// The handler of OrderApi; it asks the users service who the customer is.
const OrderHandler = struct {
    /// The client of the users service. main owns it, and it outlives the
    /// server that runs this handler.
    users: *rpc.Client,
    users_timeout: std.Io.Duration,
    next_id: std.atomic.Value(u64) = .init(1001),

    pub const rpc_handler = rpc.implement(orders_api.OrderApi, .{
        // A whole call may take 2 seconds, the call to users included.
        .defaults = .{ .timeout_ms = 2000 },
    });

    pub fn placeOrder(self: *OrderHandler, ctx: *rpc.Context, req: orders_api.PlaceOrderRequest) !orders_api.Order {
        // ctx.operation() gives the nested call what is left of this
        // call's deadline, its cancellation and its trace.
        var found = self.users.call(ctx.io(), ctx.operation(), users_api.UserApi.getUser, .{ .id = req.user_id }, .{
            .timeout = self.users_timeout,
        }) catch {
            // This call ran out of time or was canceled: that ends it.
            try ctx.operation().check(std.Io.Clock.awake.now(ctx.io()));
            // It still runs, so the users service failed it.
            return error.UsersUnavailable;
        };
        defer found.deinit();
        const customer = switch (found.outcome) {
            .ok => |user| user,
            .failure => |failure| return if (failure.code == .not_found) error.UnknownUser else error.UsersUnavailable,
        };
        // The rules of Item keep the total within a u64. The arithmetic is
        // checked all the same: an overflow is then the failure `internal`,
        // while an unchecked one would stop the whole service.
        var total: u64 = 0;
        for (req.items) |item| total = try std.math.add(u64, total, try std.math.mul(u64, item.price_cents, item.quantity));
        return .{
            .id = self.next_id.fetchAdd(1, .monotonic),
            // The name lives in `found`, which deinit frees on return: the
            // response takes a copy in the arena of this call.
            .customer = try ctx.allocator().dupe(u8, customer.name),
            .total_cents = total,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    const shop = logger.scoped("shop");

    // The users service, with one user.
    var repo: UserRepository = .init(gpa);
    defer repo.deinit();
    _ = try repo.insert(.root, io, init.arena.allocator(), "Ada Lovelace", "ada@example.com");
    var users: UserHandler = .{ .repo = &repo };
    var users_link: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer users_link.deinit(io);
    var users_server = try rpc.Server.init(gpa, .{ .transport = users_link.serverTransport(), .handlers = .{&users} });
    defer users_server.deinit(io);
    try users_server.start(io);

    // The orders service: its client of users, then its handler and server.
    // The defers stop the server first, then free the client it uses.
    var breaker: CircuitBreaker = .{ .logger = logger.scoped("breaker") };
    var users_client = try rpc.Client.init(gpa, .{
        .transport = users_link.clientTransport(),
        .middleware = .{&breaker},
    });
    defer users_client.deinit();
    var orders: OrderHandler = .{
        .users = &users_client,
        .users_timeout = .fromMilliseconds(config.users.timeout_ms),
    };
    var orders_link: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer orders_link.deinit(io);
    var orders_server = try rpc.Server.init(gpa, .{ .transport = orders_link.serverTransport(), .handlers = .{&orders} });
    defer orders_server.deinit(io);
    try orders_server.start(io);

    // The shop, a client of orders.
    var client = try rpc.Client.init(gpa, .{ .transport = orders_link.clientTransport() });
    defer client.deinit();

    // A shop built against an older orders-api, whose Item had no rule for
    // price_cents, sends a price no item has. The server checks the rules
    // of the request again and refuses it before the handler runs.
    try placeOrder(&client, io, shop, OldOrderApi.placeOrder, .{ .user_id = 1, .items = &.{
        .{ .sku = "grinder", .quantity = 2, .price_cents = 9_223_372_036_854_775_808 },
    } });

    // The service goes on.
    const items: []const orders_api.Item = &.{
        .{ .sku = "coffee-beans", .quantity = 2, .price_cents = 1450 },
        .{ .sku = "grinder", .quantity = 1, .price_cents = 4900 },
    };
    for ([_]u64{ 1, 7 }) |user_id| {
        try placeOrder(&client, io, shop, orders_api.OrderApi.placeOrder, .{ .user_id = user_id, .items = items });
    }

    // Without the users service, orders fails its calls on its own terms.
    try users_server.shutdown(io);
    shop.info("Users service stopped", .{});
    try placeOrder(&client, io, shop, orders_api.OrderApi.placeOrder, .{ .user_id = 1, .items = items });
    try placeOrder(&client, io, shop, orders_api.OrderApi.placeOrder, .{ .user_id = 1, .items = items });
}

/// OrderApi as an older orders-api had it, before Item had a rule for
/// price_cents. Its route is the same, so its calls reach the orders
/// service.
const OldOrderApi = rpc.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{ .placeOrder = rpc.method(OldPlaceOrderRequest, orders_api.Order) },
});
const OldPlaceOrderRequest = struct { user_id: u64, items: []const OldItem };
const OldItem = struct { sku: []const u8, quantity: u32, price_cents: u64 };

fn placeOrder(client: *rpc.Client, io: std.Io, shop: log.Logger, comptime method: anytype, request: @TypeOf(method).Request) !void {
    const ctx: core.Context = .root;
    var placed = try client.call(io, ctx, method, request, .{});
    defer placed.deinit();
    switch (placed.outcome) {
        .ok => |order| shop.info("Order placed", .{ .order_id = order.id, .customer = order.customer, .total_cents = order.total_cents }),
        .failure => |failure| {
            shop.warn("Order refused", .{ .user_id = request.user_id, .code = failure.code, .app_code = failure.app_code, .reason = failure.message });
            for (failure.violations) |violation| {
                shop.warn("Violation", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
            }
        },
    }
}
