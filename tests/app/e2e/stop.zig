//! The stop of an App while its servers work: an HTTP request and an RPC
//! call that began before the stop end with their answers, and neither
//! server takes anything new meanwhile.

const std = @import("std");
const zefir = @import("zefir");
const runtime = @import("runtime");
const client = @import("client.zig");

const http = zefir.http;
const rpc = zefir.rpc;
const Io = std.Io;
const testing = std.testing;

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{},
});

/// What the test sees of the work of the servers, and the gate that holds
/// it: a root value.
const Probe = struct {
    request_in: Io.Event = .unset,
    call_in: Io.Event = .unset,
    /// Opened by the test once it has seen what the stop does meanwhile.
    release: Io.Event = .unset,
};

/// `GET /slow`: works until the test opens the gate.
const Slow = struct {
    probe: *Probe,

    pub const http_routes = http.routes(.{ .methods = .{ .slow = http.get("/slow", .{}) } });

    pub fn slow(self: *Slow, ctx: *http.Context) !void {
        self.probe.request_in.set(ctx.io());
        try self.probe.release.wait(ctx.io());
        try ctx.response.text("done");
    }
};

/// A call that works until the test opens the gate.
const SlowUsers = struct {
    probe: *Probe,

    /// A limit of its own: the default 3 s could end the call before the
    /// test opens the gate on a slow runner.
    pub const rpc_handler = rpc.implement(UserApi, .{ .defaults = .{ .timeout_ms = 30_000 } });

    pub fn getUser(self: *SlowUsers, ctx: *rpc.Context, req: GetUserRequest) !User {
        self.probe.call_in.set(ctx.io());
        try self.probe.release.wait(ctx.io());
        return .{ .id = req.id, .name = "Ann" };
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .controllers = &.{Slow},
        .handlers = &.{SlowUsers},
        .factories = &.{ Net, Bus, Servers },
        .values = &.{*Probe},
    };

    pub const Net = struct {
        pub fn net(gpa: std.mem.Allocator) !http.native.Backend {
            return .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        }
    };

    pub const Bus = struct {
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, net: *http.native.Backend, controllers: zefir.app.Controllers(Root)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{ .listen = .{ .backend = net.backend() } });
        }

        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: zefir.app.Handlers(Root)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() });
        }
    };
};

test "a stop during an HTTP request and an RPC call: both end, nothing new is taken" {
    try runtime.forEachRuntime(testing.allocator, stopDuringWork);
}

fn stopDuringWork(io: Io) !void {
    var dog: runtime.Watchdog = try .start(io, "a stop during an HTTP request and an RPC call", 30);
    defer dog.stop(io);
    var probe: Probe = .{};
    var app = try zefir.App(Root).init(testing.allocator, io, .{&probe}, .{});
    defer app.deinit();
    try app.start();
    const port = app.get(http.native.Backend).port();
    var users: rpc.Client = try .init(testing.allocator, .{}, .{ .transport = app.get(rpc.testing.MemoryTransport).clientTransport() });
    defer users.deinit();

    // A request and a call at work, each on a task of its own. Whatever
    // fails below, the gate opens and both tasks are gathered before the
    // App stops.
    var request = try io.concurrent(getSlow, .{ io, port });
    var request_done = false;
    defer if (!request_done) if (request.cancel(io)) |_| {} else |_| {};
    var call = try io.concurrent(callSlow, .{ io, &users });
    var call_done = false;
    defer if (!call_done) if (call.cancel(io)) |_| {} else |_| {};
    defer probe.release.set(io);
    try within(io, &probe.request_in, 5000);
    try within(io, &probe.call_in, 5000);

    const asked = Io.Clock.awake.now(io);
    app.requestStop();
    // The first phase of the stop asks both servers to stop at once: they
    // drain what they have and take nothing new.
    const http_server: *http.Server = app.get(http.Server);
    const rpc_server: *rpc.Server = app.get(rpc.Server);
    while (http_server.state() != .draining or rpc_server.state() != .draining) {
        if (sinceMs(io, asked) > 1000) {
            std.debug.print("1 s after requestStop the servers are {t} and {t}\n", .{ http_server.state(), rpc_server.state() });
            return error.TestNotDraining;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // Each server shows draining before its own task closes the listener
    // and drains the transport: wait for those, a second at most.
    const address: Io.net.IpAddress = try .parseIp4("127.0.0.1", port);
    while (address.connect(io, .{ .mode = .stream })) |stream| {
        stream.close(io);
        if (sinceMs(io, asked) > 1000) return error.TestConnectedWhileDraining;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else |_| {}
    const bus = app.get(rpc.testing.MemoryTransport);
    while (bus.isReady()) {
        if (sinceMs(io, asked) > 1000) return error.TestTransportNotDrained;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    var refused = users.call(io, .root, UserApi.getUser, .{ .id = 2 }, .{});
    if (refused) |*result| {
        result.deinit();
        return error.TestCallTakenWhileDraining;
    } else |err| try testing.expectEqual(error.Unavailable, err);

    // The work that began before the stop ends with its answers.
    probe.release.set(io);
    request_done = true;
    try testing.expectEqualStrings("done", try request.await(io));
    call_done = true;
    try testing.expectEqualStrings("Ann", try call.await(io));
    try app.wait();
    // On Windows a refused connect alone takes about 2 s.
    const took = sinceMs(io, asked);
    if (took >= 5000) {
        std.debug.print("the stop took {d} ms\n", .{took});
        return error.TestStopTooSlow;
    }
    try testing.expectEqual(zefir.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
}

/// The body of `GET /slow`, which must be 200.
fn getSlow(io: Io, port: u16) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const res = try client.fetch(io, testing.allocator, arena_state.allocator(), port, "/slow", null);
    if (res.status != 200) return error.TestNot200;
    return if (std.mem.eql(u8, res.body, "done")) "done" else error.TestWrongBody;
}

/// The name of user 1 that the slow call answers.
fn callSlow(io: Io, users: *rpc.Client) ![]const u8 {
    var result = try users.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{ .timeout = .fromSeconds(30) });
    defer result.deinit();
    return switch (result.outcome) {
        .ok => |user| if (std.mem.eql(u8, user.name, "Ann")) "Ann" else error.TestWrongName,
        .failure => error.TestCallFailed,
    };
}

/// Waits for `event`, `limit_ms` at most.
fn within(io: Io, event: *Io.Event, limit_ms: i64) !void {
    event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(limit_ms), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return error.TestTimeout,
        else => |e| return e,
    };
}

fn sinceMs(io: Io, start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
}
