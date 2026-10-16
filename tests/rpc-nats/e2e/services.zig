//! The services of the end-to-end tests, users and orders: their contracts,
//! their handlers, and `Node`, one service on NATS with a connection of its
//! own, the transport, the server of its handler and a client for the
//! services it calls.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const nats = @import("nats");

pub const GetUserRequest = struct { id: u64 };
pub const User = struct { id: u64, name: []const u8 };

pub const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

pub const ListOrdersRequest = struct { user_id: u64 };
pub const Order = struct { id: u64, total_cents: u64 };
pub const OrderList = struct { orders: []const Order };

pub const OrderApi = rpc.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{ .listOrders = rpc.method(ListOrdersRequest, OrderList) },
});

/// Users: only user 1, Alex, exists.
pub const Users = struct {
    calls: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(self: *Users, ctx: *rpc.Context, req: GetUserRequest) !User {
        _ = ctx;
        _ = self.calls.fetchAdd(1, .monotonic);
        if (req.id != 1) return error.UserNotFound;
        return .{ .id = 1, .name = "Alex" };
    }
};

/// Orders: two orders of every user.
pub const Orders = struct {
    calls: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = rpc.implement(OrderApi, .{});

    pub fn listOrders(self: *Orders, ctx: *rpc.Context, req: ListOrdersRequest) !OrderList {
        _ = ctx;
        _ = self.calls.fetchAdd(1, .monotonic);
        const orders: []const Order = &.{ .{ .id = req.user_id * 10 + 1, .total_cents = 4900 }, .{ .id = req.user_id * 10 + 2, .total_cents = 1698 } };
        return .{ .orders = orders };
    }
};

/// A client that reconnects at once: the tests stop and start brokers.
pub const fast_reconnect: nats.ReconnectOptions = .{ .min_delay = .fromMilliseconds(50), .max_delay = .fromMilliseconds(500) };

/// One service on NATS. Initialize in place; it stays where it is.
pub const Node = struct {
    nc: nats.Client,
    adapter: rpc_nats.ZefirNats,
    bus: rpc_nats.Transport,
    server: ?rpc.Server,
    client: rpc.Client,

    /// Connects to `url`, as the NATS user `user` with the password of the
    /// same name when there is one, and makes the transport and a client.
    pub fn init(n: *Node, io: Io, url: []const u8, user: ?[]const u8, options: rpc_nats.Transport.Options) !void {
        n.nc = try .init(testing.allocator, io, .{
            .servers = &.{url},
            .auth = if (user) |u| .{ .user_password = .{ .username = u, .password = u } } else .none,
            .reconnect = fast_reconnect,
        });
        errdefer n.nc.deinit();
        try n.nc.connect();
        n.adapter = .{ .client = &n.nc };
        n.bus = try .init(testing.allocator, n.adapter.conn(), options);
        errdefer n.bus.deinit(io);
        n.client = try .init(testing.allocator, .{ .transport = n.bus.clientTransport() });
        n.server = null;
    }

    /// Serves `handler` on the transport.
    pub fn serve(n: *Node, io: Io, handler: anytype) !void {
        n.server = try rpc.Server.init(testing.allocator, .{ .transport = n.bus.serverTransport(), .handlers = .{handler} });
        errdefer {
            n.server.?.deinit(io);
            n.server = null;
        }
        try n.server.?.start(io);
    }

    /// After every call has returned.
    pub fn deinit(n: *Node, io: Io) void {
        n.client.deinit();
        if (n.server) |*s| s.deinit(io);
        n.bus.deinit(io);
        n.nc.deinit();
    }
};
