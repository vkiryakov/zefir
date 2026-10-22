//! Two servers in one App: zefir-http on `http.native` over loopback and
//! zefir-rpc on the memory transport, results of the factories of one
//! module, with the controllers and the handler App builds for them.

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
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

/// The names both servers read: a provider without fields.
const Names = struct {
    pub fn of(_: *Names, id: u64) ?[]const u8 {
        return if (id == 1) "Ann" else null;
    }
};

/// `GET /ping`: a controller without fields, as many health checks are.
const Ping = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .ping = http.get("/ping", .{}) } });

    pub fn ping(_: *Ping, ctx: *http.Context) !void {
        try ctx.response.text("pong");
    }
};

/// `GET /hello/{id}`: a controller with a field, which App fills.
const Greeter = struct {
    names: *Names,

    pub const http_routes = http.routes(.{ .methods = .{ .hello = http.get("/hello/{id}", .{}) } });

    pub fn hello(self: *Greeter, ctx: *http.Context) !void {
        const path = try ctx.path(struct { id: u64 });
        const name = self.names.of(path.id) orelse "nobody";
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "hello, {s}", .{name}));
    }
};

const Users = struct {
    names: *Names,

    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(self: *Users, _: *rpc.Context, req: GetUserRequest) !User {
        return .{ .id = req.id, .name = self.names.of(req.id) orelse return error.UserNotFound };
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{Names},
        .controllers = &.{ Ping, Greeter },
        .handlers = &.{Users},
        .factories = &.{ Net, Bus, Servers },
    };

    pub const Net = struct {
        /// The network of the HTTP server, a bean of its own so that the
        /// test reads the port the system gave.
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

test "http and rpc in one App: requests to both" {
    try runtime.forEachRuntime(testing.allocator, requestsToBoth);
}

fn requestsToBoth(io: Io) !void {
    var dog: runtime.Watchdog = try .start(io, "http and rpc in one App", 30);
    defer dog.stop(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try zefir.App(Root).init(testing.allocator, io, .{}, .{});
    defer app.deinit();
    try app.start();
    try testing.expect(app.isReady());

    // The port the system gave, once the server listens.
    const port = app.get(http.native.Backend).port();
    const pong = try client.fetch(io, testing.allocator, arena, port, "/ping", null);
    try testing.expectEqual(200, pong.status);
    try testing.expectEqualStrings("pong", pong.body);
    const hello = try client.fetch(io, testing.allocator, arena, port, "/hello/1", null);
    try testing.expectEqual(200, hello.status);
    try testing.expectEqualStrings("hello, Ann", hello.body);

    var users: rpc.Client = try .init(testing.allocator, .{}, .{ .transport = app.get(rpc.testing.MemoryTransport).clientTransport() });
    defer users.deinit();
    var found = try users.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer found.deinit();
    try testing.expectEqualStrings("Ann", found.outcome.ok.name);

    app.requestStop();
    try app.wait();
    try testing.expectEqual(zefir.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
    try testing.expectEqual(http.Server.State.stopped, app.get(http.Server).state());
    try testing.expectEqual(rpc.Server.State.stopped, app.get(rpc.Server).state());
}
