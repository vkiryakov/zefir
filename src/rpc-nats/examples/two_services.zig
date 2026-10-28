//! Two services on a NATS server with the permissions of the guide: users,
//! and orders, which calls it. Each connects as a NATS user of its own,
//! with a password from its settings, and receives its responses in an
//! inbox of its own. A transport of orders without that inbox cannot
//! subscribe to its responses: the broker refuses, and its first call fails
//! with `AccessDenied`.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL               the NATS server; nats://127.0.0.1:4222 by default
//!   APP_USERS_NATS_PASSWORD    the password of the NATS user "users"
//!   APP_ORDERS_NATS_PASSWORD   the password of the NATS user "orders"

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const nats = @import("nats");
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const zio = @import("zio");
const api = @import("users-api");
const users = @import("users-service");

/// The NATS client and the transport log through std.log; this sends their
/// records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
    users: struct {
        nats_user: []const u8 = "users",
        nats_password: confy.Secret,
    },
    orders: struct {
        nats_user: []const u8 = "orders",
        nats_password: confy.Secret,
    },
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

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    // The users service, as its NATS user. It calls no one, so its inbox
    // stays unused; its permissions give it _INBOX_users all the same.
    var users_nc: nats.Client = try .init(gpa, io, .{
        .servers = &.{config.nats.url},
        .name = "user-service",
        .auth = .{ .user_password = .{ .username = config.users.nats_user, .password = config.users.nats_password.expose() } },
    });
    defer users_nc.deinit();
    try users_nc.connect();
    var users_bus: rpc_nats.Transport = try .init(gpa, &users_nc, .{ .inbox_prefix = "_INBOX_users" });
    defer users_bus.deinit(io);
    var repo: users.UserRepository = .init(gpa);
    defer repo.deinit();
    _ = try repo.insert(.root, io, init.arena.allocator(), "Ada Lovelace", "ada@example.com");
    var handler: users.UserHandler = .{ .repo = &repo };
    var server = try rpc.Server.init(gpa, .{ .handlers = .{&handler} }, .{ .transport = users_bus.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    logger.scoped("users").info("Serving", .{ .nats_user = config.users.nats_user });

    // Orders, as its own NATS user, with its responses in _INBOX_orders.
    var orders_nc: nats.Client = try .init(gpa, io, .{
        .servers = &.{config.nats.url},
        .name = "order-service",
        .auth = .{ .user_password = .{ .username = config.orders.nats_user, .password = config.orders.nats_password.expose() } },
    });
    defer orders_nc.deinit();
    try orders_nc.connect();
    var orders_bus: rpc_nats.Transport = try .init(gpa, &orders_nc, .{ .inbox_prefix = "_INBOX_orders" });
    defer orders_bus.deinit(io);
    var client = try rpc.Client.init(gpa, .{}, .{ .transport = orders_bus.clientTransport() });
    defer client.deinit();
    const orders_log = logger.scoped("orders");
    try getUser(&client, io, orders_log, "_INBOX_orders");

    // The same NATS user with the default inbox, _INBOX: the broker refuses
    // the subscription, and the first call says so. A second transport on
    // one connection makes an adapter of its own, as every init does.
    var default_bus: rpc_nats.Transport = try .init(gpa, &orders_nc, .{});
    defer default_bus.deinit(io);
    var default_client = try rpc.Client.init(gpa, .{}, .{ .transport = default_bus.clientTransport() });
    defer default_client.deinit();
    try getUser(&default_client, io, orders_log, "_INBOX");
}

fn getUser(client: *rpc.Client, io: std.Io, orders_log: log.Logger, inbox: []const u8) !void {
    var found = client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{}) catch |err| switch (err) {
        error.AccessDenied => return orders_log.warn("Call failed", .{ .inbox = inbox, .reason = err }),
        else => return err,
    };
    defer found.deinit();
    switch (found.outcome) {
        .ok => |user| orders_log.info("User found", .{ .inbox = inbox, .id = user.id, .name = user.name }),
        .failure => |failure| orders_log.warn("Call failed", .{ .inbox = inbox, .code = failure.code, .app_code = failure.app_code }),
    }
}
