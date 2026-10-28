//! The snippets of README.md, the guide of zefir-nats, that are no part of
//! a whole program: each is the body of a function here, so the compiler
//! checks every line the guide shows. They need a NATS server, so the
//! build compiles them and runs none; the whole programs of the guide run
//! against real servers.

const std = @import("std");
const log = @import("log");
const nats = @import("nats");

/// The first look of the guide: connect, subscribe, publish, and take the
/// message.
pub fn firstLook(gpa: std.mem.Allocator, io: std.Io) !void {
    var client: nats.Client = try .init(gpa, io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    try client.connect();

    const sub = try client.subscribe("orders.>", .{});
    defer sub.deinit();
    try client.publish("orders.created", "{\"id\":1001}");

    var msg = (try sub.next(.{})) orelse return;
    defer msg.deinit();
    std.log.info("{s}: {s}", .{ msg.subject, msg.payload });
}

/// A client of a service with two servers of a cluster, a name, a shorter
/// time for each attempt to connect, and no echo of its own messages.
pub fn connectWithOptions(gpa: std.mem.Allocator, io: std.Io) !void {
    var client: nats.Client = try .init(gpa, io, .{
        .servers = &.{ "nats://10.0.0.1:4222", "nats://10.0.0.2:4222" },
        .name = "orders-service",
        .connect_timeout = .fromSeconds(2),
        .no_echo = true,
    });
    defer client.deinit();
    try client.connect();
}

/// A publish with headers.
pub fn publishWithHeaders(client: *nats.Client) !void {
    try client.publishMessage(.{
        .subject = "orders.cancelled",
        .headers = &.{
            .{ .name = "Reason", .value = "out-of-stock" },
            .{ .name = "Trace-Id", .value = "4bf92f3577b34da6" },
        },
        .payload = "{\"id\":1002}",
    });
}

/// Reads a subscription until it ends.
pub fn readOrders(client: *nats.Client) !void {
    const sub = try client.subscribe("orders.*", .{});
    defer sub.deinit();
    while (true) {
        var msg = (try sub.next(.{})) orelse break;
        defer msg.deinit();
        std.log.info("{s}: {s}", .{ msg.subject, msg.payload });
    }
}

/// Waits a second at most for the next message.
pub fn nextWithinASecond(sub: *nats.Subscription) !void {
    var msg = (sub.next(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } } }) catch |err| switch (err) {
        error.Timeout => return, // nothing came within a second
        else => |e| return e,
    }) orelse return;
    defer msg.deinit();
    std.log.info("{s}: {s}", .{ msg.subject, msg.payload });
}

/// A publish and a subscribe that wait no longer than two seconds for
/// room in the outbound queue.
pub fn waitForRoomAtMost(client: *nats.Client) !void {
    const two_seconds: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
    client.publishMessageTimeout(.{ .subject = "orders.created", .payload = "{\"id\":1003}" }, two_seconds) catch |err| switch (err) {
        // The queue stayed full for two seconds: nothing was queued.
        error.Timeout => std.log.warn("orders.created was not published", .{}),
        else => |e| return e,
    };
    const refunds = try client.subscribe("refunds.>", .{ .timeout = two_seconds });
    defer refunds.deinit();
}

/// A subscription with room for a burst.
pub fn roomForABurst(client: *nats.Client) !void {
    // A subscription that may fall behind by 100,000 messages or 256 MiB in a
    // burst, and keeps the newest messages when it does.
    const audit = try client.subscribe("audit.>", .{
        .pending = .{ .messages = 100_000, .bytes = 256 * 1024 * 1024 },
        .overflow = .drop_oldest,
    });
    defer audit.deinit();
}

/// A burst that a subscriber with the default limits does not read: most
/// of it is dropped, and counted.
pub fn burst(mailer: *nats.Client, shop: *nats.Client, mailer_log: log.Logger) !void {
    // The default limits: 1024 messages and 8 MiB.
    const order_events = try mailer.subscribe("orders.>", .{});
    defer order_events.deinit();
    try mailer.flush(.{});

    // A sale: the shop publishes 10,000 orders at once, and the mailer is
    // busy with something else and reads none of them yet.
    for (0..10_000) |i| {
        var buffer: [32]u8 = undefined;
        try shop.publish("orders.created", try std.fmt.bufPrint(&buffer, "{{\"id\":{d}}}", .{i}));
    }
    try shop.flush(.{});
    // The server answers this flush after every order it sent the mailer,
    // so when it returns, the client has taken all of them in.
    try mailer.flush(.{});

    const stats = order_events.stats();
    mailer_log.info("Burst over", .{
        .received = stats.received,
        .waiting = order_events.pending().messages,
        .dropped = stats.dropped,
    });
}

/// The counters of the client.
pub fn logStats(client: *nats.Client) void {
    const stats = client.stats();
    std.log.info("in {d}, out {d}, dropped {d}, uncertain {d}, reconnects {d}", .{
        stats.messages_in, stats.messages_out, stats.dropped_messages, stats.uncertain_outbound_frames, stats.reconnects,
    });
}

/// A subscription that the permissions of the user may refuse, checked
/// before any message is due.
pub fn subscribeToPayments(client: *nats.Client) !void {
    const payments = try client.subscribe("payments.>", .{});
    defer payments.deinit();
    try client.flush(.{});
    // The permissions of this user do not let it read payments.
    if (payments.isDenied()) return error.PaymentsNotAllowed;
}

/// Connects `client` where it will stay: once connected, a client must not move.
fn connectInPlace(client: *nats.Client, gpa: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    client.* = try .init(gpa, io, .{ .servers = &.{url} });
    errdefer client.deinit();
    try client.connect();
}

/// A client connected through a pointer, where it lives.
pub fn connectThroughAPointer(gpa: std.mem.Allocator, io: std.Io) !void {
    var client: nats.Client = undefined;
    try connectInPlace(&client, gpa, io, "nats://127.0.0.1:4222");
    defer client.deinit();
    try client.publish("orders.created", "{\"id\":1001}");
}

/// What the root file of a program declares on Windows, where std prints
/// a stack trace in Debug builds for the read that ends a connection the
/// client shut down.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn, .unexpected_error_tracing = false };

test {
    std.testing.refAllDecls(@This());
}
