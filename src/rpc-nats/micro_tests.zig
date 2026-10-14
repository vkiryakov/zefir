//! NATS micro discovery on `FakeConn`, through the real engine: what
//! `nats micro ls`, `info` and `stats` ask, in all three forms of subject,
//! and the JSON they get, field by field as ADR-32 and nats.go write it.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const FakeConn = @import("testing/FakeConn.zig");
const micro = @import("micro.zig");

const testing = std.testing;

const get_user: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };
const create_user: rpc.Route = .{ .service = "users", .version = 1, .method = "createUser" };
const get_user_v2: rpc.Route = .{ .service = "users", .version = 2, .method = "getUser" };
const place_order: rpc.Route = .{ .service = "orders", .version = 1, .method = "place" };

/// A method on bytes that echoes the request, and fails when it is
/// "missing".
const Echo = struct {
    fn handle(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        if (std.mem.eql(u8, request, "missing")) return ctx.fail(.{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" });
        return request;
    }
};

/// The PING response: the identity of a service.
const Ping = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8,
    metadata: std.json.Value,
    type: []const u8,
};

const EndpointInfo = struct {
    name: []const u8,
    subject: []const u8,
    queue_group: []const u8,
    metadata: std.json.Value,
};

const Info = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8,
    metadata: std.json.Value,
    type: []const u8,
    description: []const u8,
    endpoints: []const EndpointInfo,
};

const EndpointStats = struct {
    name: []const u8,
    subject: []const u8,
    queue_group: []const u8,
    num_requests: u64,
    num_errors: u64,
    last_error: []const u8,
    processing_time: i64,
    average_processing_time: i64,
};

const Stats = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8,
    metadata: std.json.Value,
    type: []const u8,
    started: []const u8,
    endpoints: []const EndpointStats,
};

/// A server of three contracts on a fake connection, and a client that is
/// not zefir asking it, as the NATS CLI does.
const Stage = struct {
    fake: FakeConn,
    bus: Transport,
    server: rpc.RawServer,
    inbox: Conn.Sub,
    arena: std.heap.ArenaAllocator,
    state: u8 = 0,
    asked: u32 = 0,

    fn init(s: *Stage, options: Transport.Options) !void {
        const io = testing.io;
        s.fake = .init(testing.allocator, .{});
        errdefer s.fake.deinit(io);
        s.bus = try .init(testing.allocator, s.fake.conn(), options);
        errdefer s.bus.deinit(io);
        try s.startServer();
        errdefer s.server.deinit(io);
        s.inbox = try s.fake.subscribe(io, "_INBOX.probe.*", null, .none);
        s.arena = .init(testing.allocator);
        s.asked = 0;
    }

    /// The four methods, in this order: users v1 getUser, orders v1
    /// place, users v1 createUser, users v2 getUser.
    fn startServer(s: *Stage) !void {
        const io = testing.io;
        const echo: rpc.Handler = .{ .ptr = &s.state, .handle = Echo.handle };
        const methods = [_]rpc.Method{
            .{ .route = get_user, .handler = echo },
            .{ .route = place_order, .handler = echo },
            .{ .route = create_user, .handler = echo },
            .{ .route = get_user_v2, .handler = echo },
        };
        s.server = try .init(testing.allocator, .{ .transport = s.bus.serverTransport(), .methods = &methods });
        errdefer s.server.deinit(io);
        try s.server.start(io);
    }

    fn deinit(s: *Stage) void {
        const io = testing.io;
        s.arena.deinit();
        s.fake.unsubscribe(io, s.inbox);
        s.server.deinit(io);
        s.bus.deinit(io);
        s.fake.deinit(io);
    }

    /// The payloads of the answers to a request on `subject`: all that come
    /// before 200 ms pass without one.
    fn ask(s: *Stage, subject: []const u8) ![]const []const u8 {
        const io = testing.io;
        s.asked += 1;
        var reply: [64]u8 = undefined;
        const reply_to = try std.fmt.bufPrint(&reply, "_INBOX.probe.{d}", .{s.asked});
        try s.fake.publish(io, .{ .subject = subject, .reply_to = reply_to }, .none);
        var answers: std.ArrayList([]const u8) = .empty;
        const a = s.arena.allocator();
        while (true) {
            const msg = s.fake.next(io, s.inbox, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => break,
                else => return err,
            } orelse break;
            defer msg.release();
            try testing.expectEqualStrings(reply_to, msg.subject);
            // No one took the request: the broker's 503, no answer.
            if (std.mem.startsWith(u8, msg.header_block, "NATS/1.0 503")) continue;
            // An answer of NATS micro has no headers.
            try testing.expectEqualStrings("", msg.header_block);
            try answers.append(a, try a.dupe(u8, msg.payload));
        }
        return answers.items;
    }

    /// The one answer to `subject`, parsed strictly as `T`.
    fn askOne(s: *Stage, comptime T: type, subject: []const u8) !T {
        const answers = try s.ask(subject);
        try testing.expectEqual(@as(usize, 1), answers.len);
        return std.json.parseFromSliceLeaky(T, s.arena.allocator(), answers[0], .{});
    }

    fn call(s: *Stage, route: rpc.Route, body: []const u8) !void {
        var client: rpc.RawClient = try .init(testing.allocator, .{ .transport = s.bus.clientTransport() });
        defer client.deinit();
        var result = try client.call(testing.io, .root, route, body, .{ .timeout = .fromSeconds(5) });
        result.deinit();
    }
};

/// The service of `name` and `version` among PING answers.
fn find(pings: []const Ping, name: []const u8, version: []const u8) !Ping {
    for (pings) |p| {
        if (std.mem.eql(u8, p.name, name) and std.mem.eql(u8, p.version, version)) return p;
    }
    return error.TestServiceNotFound;
}

test "every contract answers PING in the three forms of subject, with an id of its own" {
    var stage: Stage = undefined;
    try stage.init(.{});
    defer stage.deinit();
    const a = stage.arena.allocator();

    const all = try stage.ask("$SRV.PING");
    try testing.expectEqual(@as(usize, 3), all.len);
    var pings: [3]Ping = undefined;
    for (all, &pings) |bytes, *p| p.* = try std.json.parseFromSliceLeaky(Ping, a, bytes, .{});
    const users = try find(&pings, "users", "1.0.0");
    const users_v2 = try find(&pings, "users", "2.0.0");
    const orders = try find(&pings, "orders", "1.0.0");
    for (pings) |p| {
        try testing.expectEqualStrings("io.nats.micro.v1.ping_response", p.type);
        try testing.expectEqual(@as(usize, micro.id_len), p.id.len);
        try testing.expectEqual(@as(usize, 0), p.metadata.object.count());
    }
    try testing.expect(!std.mem.eql(u8, users.id, users_v2.id));
    try testing.expect(!std.mem.eql(u8, users.id, orders.id));
    // The exact bytes, as nats.go writes them.
    const expected = try std.fmt.allocPrint(a, "{{\"name\":\"orders\",\"id\":\"{s}\",\"version\":\"1.0.0\",\"metadata\":{{}},\"type\":\"io.nats.micro.v1.ping_response\"}}", .{orders.id});
    var exact = false;
    for (all) |bytes| exact = exact or std.mem.eql(u8, bytes, expected);
    try testing.expect(exact);

    // By name: both versions of users.
    const named = try stage.ask("$SRV.PING.users");
    try testing.expectEqual(@as(usize, 2), named.len);
    for (named) |bytes| try testing.expectEqualStrings("users", (try std.json.parseFromSliceLeaky(Ping, a, bytes, .{})).name);
    // By id: one.
    const one = try stage.askOne(Ping, try std.fmt.allocPrint(a, "$SRV.PING.users.{s}", .{users_v2.id}));
    try testing.expectEqualStrings("2.0.0", one.version);
    // Another name or id: nobody.
    try testing.expectEqual(@as(usize, 0), (try stage.ask("$SRV.PING.billing")).len);
    try testing.expectEqual(@as(usize, 0), (try stage.ask("$SRV.PING.users.AAAAAAAAAAAAAAAAAAAAAA")).len);
}

test "INFO lists the methods of a contract with their subjects and queue group" {
    var stage: Stage = undefined;
    try stage.init(.{ .subject_prefix = "shop", .queue_group = "users-workers" });
    defer stage.deinit();
    const a = stage.arena.allocator();
    const answers = try stage.ask("$SRV.INFO.users");
    try testing.expectEqual(@as(usize, 2), answers.len);
    for (answers) |bytes| {
        const info = try std.json.parseFromSliceLeaky(Info, a, bytes, .{});
        try testing.expectEqualStrings("io.nats.micro.v1.info_response", info.type);
        try testing.expectEqualStrings("", info.description);
        for (info.endpoints) |e| {
            try testing.expectEqualStrings("users-workers", e.queue_group);
            try testing.expect(e.metadata == .null);
        }
        if (std.mem.eql(u8, info.version, "1.0.0")) {
            // In the order of the server's methods.
            try testing.expectEqual(@as(usize, 2), info.endpoints.len);
            try testing.expectEqualStrings("getUser", info.endpoints[0].name);
            try testing.expectEqualStrings("shop.users.v1.getUser", info.endpoints[0].subject);
            try testing.expectEqualStrings("createUser", info.endpoints[1].name);
            try testing.expectEqualStrings("shop.users.v1.createUser", info.endpoints[1].subject);
        } else {
            try testing.expectEqualStrings("2.0.0", info.version);
            try testing.expectEqual(@as(usize, 1), info.endpoints.len);
            try testing.expectEqualStrings("shop.users.v2.getUser", info.endpoints[0].subject);
        }
    }
    try testing.expectEqual(@as(usize, 3), (try stage.ask("$SRV.INFO")).len);
    const ping = try stage.askOne(Ping, "$SRV.PING.orders");
    const orders = try stage.askOne(Info, try std.fmt.allocPrint(a, "$SRV.INFO.orders.{s}", .{ping.id}));
    try testing.expectEqualStrings("shop.orders.v1.place", orders.endpoints[0].subject);
}

test "STATS counts the calls of every method, its failures and its time" {
    var stage: Stage = undefined;
    try stage.init(.{});
    defer stage.deinit();
    const a = stage.arena.allocator();
    const before = std.Io.Clock.real.now(testing.io);
    try stage.call(get_user, "1");
    try stage.call(get_user, "2");
    try stage.call(get_user, "missing");
    try stage.call(create_user, "x");

    var stats: ?Stats = null;
    for (try stage.ask("$SRV.STATS.users")) |bytes| {
        const s = try std.json.parseFromSliceLeaky(Stats, a, bytes, .{});
        if (std.mem.eql(u8, s.version, "1.0.0")) stats = s;
    }
    const s = stats orelse return error.TestNoStats;
    try testing.expectEqualStrings("io.nats.micro.v1.stats_response", s.type);
    // RFC 3339 in UTC, from the start of the server, which came before.
    try testing.expectEqual(@as(usize, micro.rfc3339_len), s.started.len);
    try testing.expectEqual(@as(u8, 'Z'), s.started[s.started.len - 1]);
    var now_text: [micro.rfc3339_len]u8 = undefined;
    try testing.expect(std.mem.order(u8, s.started, micro.rfc3339(&now_text, before)) != .gt);

    const get = s.endpoints[0];
    try testing.expectEqualStrings("getUser", get.name);
    try testing.expectEqualStrings("users.v1.getUser", get.subject);
    try testing.expectEqualStrings("q", get.queue_group);
    try testing.expectEqual(@as(u64, 3), get.num_requests);
    try testing.expectEqual(@as(u64, 1), get.num_errors);
    try testing.expectEqualStrings("404:users.not_found", get.last_error);
    try testing.expect(get.processing_time > 0);
    try testing.expectEqual(@divFloor(get.processing_time, 3), get.average_processing_time);

    const create = s.endpoints[1];
    try testing.expectEqual(@as(u64, 1), create.num_requests);
    try testing.expectEqual(@as(u64, 0), create.num_errors);
    try testing.expectEqualStrings("", create.last_error);

    // Nothing called yet: zeros.
    for (try stage.ask("$SRV.STATS.orders")) |bytes| {
        const orders = try std.json.parseFromSliceLeaky(Stats, a, bytes, .{});
        try testing.expectEqual(@as(u64, 0), orders.endpoints[0].num_requests);
        try testing.expectEqual(@as(i64, 0), orders.endpoints[0].average_processing_time);
    }
}

test "the answers go only to a reply subject under reply_prefixes" {
    var stage: Stage = undefined;
    try stage.init(.{});
    defer stage.deinit();
    const io = testing.io;
    const foreign = try stage.fake.subscribe(io, "elsewhere.*", null, .none);
    defer stage.fake.unsubscribe(io, foreign);
    try stage.fake.publish(io, .{ .subject = "$SRV.PING", .reply_to = "elsewhere.1" }, .none);
    try stage.fake.publish(io, .{ .subject = "$SRV.INFO" }, .none);
    try testing.expectError(error.Timeout, stage.fake.next(io, foreign, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }));
    // Three services each dropped both.
    const counters = stage.bus.counters();
    try testing.expectEqual(@as(u64, 3), counters.requests_with_foreign_reply_to);
    try testing.expectEqual(@as(u64, 3), counters.requests_without_reply_to);
}

test "with discovery off there are no subscriptions of NATS micro" {
    var stage: Stage = undefined;
    try stage.init(.{ .discovery = .{ .enabled = false } });
    defer stage.deinit();
    const io = testing.io;
    // The four routes and the probe's inbox.
    try testing.expectEqual(@as(usize, 5), stage.fake.subscriptionCount(io));
    try testing.expect(!stage.fake.hasSubscription(io, "$SRV.PING", null));
    try testing.expectEqual(@as(usize, 0), (try stage.ask("$SRV.PING")).len);
}

test "discovery subscribes nine subjects per contract without a queue group, and close ends them" {
    var stage: Stage = undefined;
    try stage.init(.{});
    defer stage.deinit();
    const io = testing.io;
    // Four routes, three contracts of nine, the probe's inbox.
    try testing.expectEqual(@as(usize, 4 + 3 * 9 + 1), stage.fake.subscriptionCount(io));
    const ping = try stage.askOne(Ping, "$SRV.PING.orders");
    for ([_][]const u8{ "PING", "INFO", "STATS" }) |verb| {
        var buffer: [64]u8 = undefined;
        try testing.expect(stage.fake.hasSubscription(io, try std.fmt.bufPrint(&buffer, "$SRV.{s}", .{verb}), null));
        try testing.expect(stage.fake.hasSubscription(io, try std.fmt.bufPrint(&buffer, "$SRV.{s}.orders", .{verb}), null));
        try testing.expect(stage.fake.hasSubscription(io, try std.fmt.bufPrint(&buffer, "$SRV.{s}.orders.{s}", .{ verb, ping.id }), null));
    }
    // A stopping replica leaves the lists: its subscriptions end.
    try stage.server.shutdown(io);
    try testing.expectEqual(@as(usize, 1), stage.fake.subscriptionCount(io));
    try testing.expectEqual(@as(usize, 0), (try stage.ask("$SRV.PING")).len);
}

test "a server started again on the transport is a new instance: new ids, a later start" {
    var stage: Stage = undefined;
    try stage.init(.{});
    defer stage.deinit();
    const io = testing.io;
    const first = try stage.askOne(Stats, "$SRV.STATS.orders");
    try stage.server.shutdown(io);
    stage.server.deinit(io);
    try stage.startServer();
    const second = try stage.askOne(Stats, "$SRV.STATS.orders");
    try testing.expect(!std.mem.eql(u8, first.id, second.id));
    try testing.expect(std.mem.order(u8, first.started, second.started) != .gt);
}
