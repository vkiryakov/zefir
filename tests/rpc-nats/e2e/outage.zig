//! A broker that goes away and comes back, between a server and a client
//! with connections of their own: a call that waits ends at its deadline,
//! a new call fails at once with Unavailable while the client reconnects,
//! and once the broker is back, calls go through again.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const nats = @import("nats");
const root = @import("root.zig");
const services = @import("services.zig");

const servers = root.servers;

const fast_route: rpc.Route = .{ .service = "clock", .version = 1, .method = "now" };
const slow_route: rpc.Route = .{ .service = "clock", .version = 1, .method = "wait" };

/// `now` answers at once; `wait` holds the call until its deadline.
const Clock = struct {
    waiting: std.atomic.Value(u32) = .init(0),

    fn now(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = ctx;
        return request;
    }

    fn wait(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        const clock: *Clock = @ptrCast(@alignCast(ptr));
        _ = clock.waiting.fetchAdd(1, .monotonic);
        try ctx.io().sleep(.fromSeconds(30), .awake);
        return request;
    }
};

/// One side's connection, adapter and transport. Initialize in place.
const Side = struct {
    nc: nats.Client,
    adapter: rpc_nats.ZefirNats,
    bus: rpc_nats.Transport,

    fn init(s: *Side, io: Io) !void {
        s.nc = try .init(testing.allocator, io, .{ .servers = &.{servers.restart}, .reconnect = services.fast_reconnect });
        errdefer s.nc.deinit();
        try s.nc.connect();
        s.adapter = .{ .client = &s.nc };
        s.bus = try .init(testing.allocator, s.adapter.conn(), .{});
    }

    fn deinit(s: *Side, io: Io) void {
        s.bus.deinit(io);
        s.nc.deinit();
    }
};

const Caller = struct {
    client: *rpc.RawClient,
    io: Io,
    result: rpc.RawClient.CallError!void = {},
    took: Io.Duration = .zero,

    fn run(c: *Caller) void {
        const began = Io.Clock.awake.now(c.io);
        defer c.took = began.durationTo(Io.Clock.awake.now(c.io));
        var r = c.client.call(c.io, .root, slow_route, "x", .{ .timeout = .fromSeconds(4) }) catch |err| {
            c.result = err;
            return;
        };
        r.deinit();
    }
};

fn connected(nc: *nats.Client) bool {
    return nc.isConnected();
}

fn disconnected(nc: *nats.Client) bool {
    return !nc.isConnected();
}

fn scenario(io: Io) !void {
    var clock: Clock = .{};
    var server_side: Side = undefined;
    try server_side.init(io);
    defer server_side.deinit(io);
    const methods = [_]rpc.Method{
        .{ .route = fast_route, .handler = .{ .ptr = &clock, .handle = Clock.now } },
        .{ .route = slow_route, .handler = .{ .ptr = &clock, .handle = Clock.wait } },
    };
    var server: rpc.RawServer = try .init(testing.allocator, .{ .transport = server_side.bus.serverTransport(), .methods = &methods, .shutdown_grace = .fromMilliseconds(100) });
    defer server.deinit(io);
    try server.start(io);

    var client_side: Side = undefined;
    try client_side.init(io);
    defer client_side.deinit(io);
    var client: rpc.RawClient = try .init(testing.allocator, .{ .transport = client_side.bus.clientTransport() });
    defer client.deinit();

    {
        var r = try client.call(io, .root, fast_route, "before", .{});
        r.deinit();
    }
    // A call waits for its answer when the broker stops: it ends at its
    // deadline, as the response may still come while the client
    // reconnects.
    var caller: Caller = .{ .client = &client, .io = io };
    var task = try io.concurrent(Caller.run, .{&caller});
    defer task.cancel(io);
    try root.eventually(io, &clock.waiting, struct {
        fn started(waiting: *std.atomic.Value(u32)) bool {
            return waiting.load(.monotonic) == 1;
        }
    }.started);
    try root.stop(io, servers.restart_container);
    // Started again, whatever happens below.
    defer root.start(io, servers.restart_container) catch |err| std.debug.print("the restart server did not start again: {t}\n", .{err});
    task.await(io);
    try testing.expectError(error.DeadlineExceeded, caller.result);
    try testing.expect(caller.took.toMilliseconds() >= 4000);
    try testing.expect(caller.took.toMilliseconds() < 9000);

    // No link: a new call fails at once, and nothing waits in a buffer.
    try root.eventually(io, &client_side.nc, disconnected);
    const began = Io.Clock.awake.now(io);
    try testing.expectError(error.Unavailable, client.call(io, .root, fast_route, "while down", .{}));
    try testing.expect(began.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 500);

    // Back: both reconnect, the server subscribes again, calls go through.
    try root.start(io, servers.restart_container);
    try root.eventually(io, &client_side.nc, connected);
    try root.eventually(io, &server_side.nc, connected);
    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (true) {
        var r = client.call(io, .root, fast_route, "after", .{ .timeout = .fromSeconds(1) }) catch |err| {
            // The server's subscriptions may still be on their way.
            if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return err;
            try io.sleep(.fromMilliseconds(50), .awake);
            continue;
        };
        defer r.deinit();
        try testing.expect(r.response.status == .ok);
        try testing.expectEqualStrings("after", r.response.body);
        break;
    }
    try server.shutdown(io);
}

test "a broker that goes away: a waiting call ends at its deadline, a new one is Unavailable at once, and calls go through once it is back" {
    try root.onZio(scenario);
}
