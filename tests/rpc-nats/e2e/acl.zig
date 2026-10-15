//! The NATS permissions of the guide of rpc-nats (A11), on the server of
//! tests/rpc-nats/conf/acl.conf: users and orders, each with a user of its
//! own and an inbox of its own, call each other; billing, another service
//! on the same broker, can neither subscribe to their routes and inboxes
//! nor see their requests and responses, nor serve or call their routes.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const root = @import("root.zig");
const services = @import("services.zig");

const servers = root.servers;

/// What billing tries to read: the routes and the inboxes of the others,
/// the default inbox and everything.
const spied = [_][]const u8{ "users.v1.>", "orders.v1.>", "_INBOX_users.>", "_INBOX_orders.>", "_INBOX.>", ">" };

fn scenario(io: Io) !void {
    var users_handler: services.Users = .{};
    var orders_handler: services.Orders = .{};
    var users: services.Node = undefined;
    try users.init(io, servers.acl, "users", .{ .inbox_prefix = "_INBOX_users" });
    defer users.deinit(io);
    try users.serve(io, &users_handler);
    var orders: services.Node = undefined;
    try orders.init(io, servers.acl, "orders", .{ .inbox_prefix = "_INBOX_orders" });
    defer orders.deinit(io);
    try orders.serve(io, &orders_handler);

    // Billing subscribes to all it would like to see; the broker refuses.
    var billing: nats.Client = try .init(testing.allocator, io, .{
        .servers = &.{servers.acl},
        .auth = .{ .user_password = .{ .username = "billing", .password = "billing" } },
    });
    defer billing.deinit();
    try billing.connect();
    var spies: [spied.len]*nats.Subscription = undefined;
    var subscribed: usize = 0;
    defer for (spies[0..subscribed]) |s| s.deinit();
    for (spied, &spies) |subject, *s| {
        s.* = try billing.subscribe(subject, .{});
        subscribed += 1;
    }
    try billing.flush(.{ .timeout = root.five_seconds });
    for (spies) |s| try testing.expect(s.isDenied());

    // Users and orders call each other.
    {
        var r = try orders.client.call(io, .root, services.UserApi.getUser, .{ .id = 1 }, .{});
        defer r.deinit();
        try testing.expectEqualStrings("Alex", r.outcome.ok.name);
    }
    {
        var r = try users.client.call(io, .root, services.OrderApi.listOrders, .{ .user_id = 1 }, .{});
        defer r.deinit();
        try testing.expectEqual(@as(usize, 2), r.outcome.ok.orders.len);
    }
    {
        var r = try orders.client.call(io, .root, services.UserApi.getUser, .{ .id = 2 }, .{});
        defer r.deinit();
        try testing.expectEqualStrings("users.not_found", r.outcome.failure.app_code);
    }
    // Billing saw none of it.
    for (spies) |s| {
        try testing.expectError(error.PermissionDenied, s.next(.{ .timeout = root.five_seconds }));
        try testing.expectEqual(@as(u64, 0), s.stats().received);
    }

    // Billing cannot serve the routes of users: its server does not start.
    var impostor: services.Node = undefined;
    try impostor.init(io, servers.acl, "billing", .{ .inbox_prefix = "_INBOX_billing" });
    defer impostor.deinit(io);
    var impostor_handler: services.Users = .{};
    try testing.expectError(error.AccessDenied, impostor.serve(io, &impostor_handler));
    // Nor call them: the broker drops a publish it denies, so the call ends
    // at its deadline, and users never hear of it.
    const calls = users_handler.calls.load(.monotonic);
    try testing.expectError(error.DeadlineExceeded, impostor.client.call(io, .root, services.UserApi.getUser, .{ .id = 1 }, .{ .timeout = .fromMilliseconds(500) }));
    try testing.expectEqual(calls, users_handler.calls.load(.monotonic));

    // A transport of orders with the default inbox: the broker refuses the
    // subscription, and the first call says so.
    var default_inbox: services.Node = undefined;
    try default_inbox.init(io, servers.acl, "orders", .{});
    defer default_inbox.deinit(io);
    try testing.expectError(error.AccessDenied, default_inbox.client.call(io, .root, services.UserApi.getUser, .{ .id = 1 }, .{}));
}

test "the NATS permissions of the guide: services call each other, and another one sees nothing of it" {
    try root.onZio(scenario);
}
