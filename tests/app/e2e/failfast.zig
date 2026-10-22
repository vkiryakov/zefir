//! A server that breaks stops the whole App, fail-fast, and a bean that
//! both servers use outlives them: App destroys its beans in the reverse
//! order of their creation, the servers before what they take.

const std = @import("std");
const zefir = @import("zefir");
const runtime = @import("runtime");
const client = @import("client.zig");

const http = zefir.http;
const rpc = zefir.rpc;
const Io = std.Io;
const testing = std.testing;

const CountRequest = struct {};
const Count = struct { orders: u32 };

const OrdersApi = rpc.Contract(.{
    .name = "orders",
    .version = 1,
    .methods = .{ .count = rpc.method(CountRequest, Count) },
    .errors = .{},
});

/// Who App destroyed, in order: a root value. App calls `deinit` from the
/// task that calls its own, one bean at a time.
const Journal = struct {
    lines: [8][]const u8 = undefined,
    len: usize = 0,

    fn add(j: *Journal, line: []const u8) void {
        j.lines[j.len] = line;
        j.len += 1;
    }
};

/// The orders both servers serve: a provider the controller and the
/// handler take.
const Store = struct {
    journal: *Journal,

    pub fn count(_: *Store) u32 {
        return 3;
    }

    pub fn deinit(store: *Store) void {
        store.journal.add("Root.Store");
    }
};

/// `GET /orders/count`.
const Orders = struct {
    store: *Store,

    pub const http_routes = http.routes(.{ .methods = .{ .count = http.get("/orders/count", .{}) } });

    pub fn count(self: *Orders, ctx: *http.Context) !void {
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{d}", .{self.store.count()}));
    }
};

const OrdersHandler = struct {
    store: *Store,

    pub const rpc_handler = rpc.implement(OrdersApi, .{});

    pub fn count(self: *OrdersHandler, _: *rpc.Context, _: CountRequest) !Count {
        return .{ .orders = self.store.count() };
    }
};

/// The HTTP server, which writes its `deinit` to the journal: a wrapper
/// that passes the lifecycle on.
const HttpServer = struct {
    server: http.Server,
    journal: *Journal,

    pub fn start(s: *HttpServer, io: Io) !void {
        return s.server.start(io);
    }
    pub fn wait(s: *HttpServer, io: Io) !void {
        return s.server.wait(io);
    }
    pub fn requestStop(s: *HttpServer, io: Io) void {
        s.server.requestStop(io);
    }
    pub fn shutdown(s: *HttpServer, io: Io, deadline: Io.Clock.Timestamp) !void {
        return s.server.shutdown(io, deadline);
    }
    pub fn isReady(s: *const HttpServer) bool {
        return s.server.isReady();
    }
    pub fn deinit(s: *HttpServer, io: Io) void {
        s.server.deinit(io);
        s.journal.add("Root.Servers.httpServer");
    }
};

/// The rpc server, which writes its `deinit` to the journal.
const RpcServer = struct {
    server: rpc.Server,
    journal: *Journal,

    pub fn start(s: *RpcServer, io: Io) !void {
        return s.server.start(io);
    }
    pub fn wait(s: *RpcServer, io: Io) !void {
        return s.server.wait(io);
    }
    pub fn requestStop(s: *RpcServer, io: Io) void {
        s.server.requestStop(io);
    }
    pub fn shutdown(s: *RpcServer, io: Io, deadline: Io.Clock.Timestamp) !void {
        return s.server.shutdown(io, deadline);
    }
    pub fn isReady(s: *const RpcServer) bool {
        return s.server.isReady();
    }
    pub fn deinit(s: *RpcServer, io: Io) void {
        s.server.deinit(io);
        s.journal.add("Root.Servers.rpcServer");
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{Store},
        .controllers = &.{Orders},
        .handlers = &.{OrdersHandler},
        .factories = &.{ Net, Bus, Servers },
        .values = &.{*Journal},
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
        pub fn httpServer(gpa: std.mem.Allocator, journal: *Journal, net: *http.native.Backend, controllers: zefir.app.Controllers(Root)) !HttpServer {
            return .{
                .server = try .init(gpa, .{ .controllers = controllers }, .{ .listen = .{ .backend = net.backend() } }),
                .journal = journal,
            };
        }

        pub fn rpcServer(gpa: std.mem.Allocator, journal: *Journal, bus: *rpc.testing.MemoryTransport, handlers: zefir.app.Handlers(Root)) !RpcServer {
            return .{
                .server = try .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() }),
                .journal = journal,
            };
        }
    };
};

test "a broken rpc server stops the App; the shared Store outlives both servers" {
    try runtime.forEachRuntime(testing.allocator, brokenRpc);
}

fn brokenRpc(io: Io) !void {
    var dog: runtime.Watchdog = try .start(io, "a broken rpc server stops the App", 30);
    defer dog.stop(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var journal: Journal = .{};
    {
        var app = try zefir.App(Root).init(testing.allocator, io, .{&journal}, .{});
        defer app.deinit();
        try app.start();
        const port = app.get(http.native.Backend).port();
        const before = try client.fetch(io, testing.allocator, arena_state.allocator(), port, "/orders/count", null);
        try testing.expectEqualStrings("3", before.body);

        // The transport breaks under the rpc server, whose wait returns
        // error.Unavailable: App stops the HTTP server too.
        app.get(rpc.testing.MemoryTransport).failServer(io, error.Unavailable);
        try testing.expectError(error.Unavailable, app.wait());
        const failure = app.failure() orelse return error.TestNoFailure;
        try testing.expectEqualStrings("Root.Servers.rpcServer", failure.bean);
        try testing.expectEqual(zefir.app.Failure.Step.wait, failure.step);
        try testing.expectEqual(error.Unavailable, failure.err);
        try testing.expectEqual(zefir.app.State.stopped, app.state());
        try testing.expectEqual(http.Server.State.stopped, app.get(HttpServer).server.state());
        try testing.expect(journal.len == 0);
    }
    // Both servers first, the last built first; the store they share last.
    try testing.expectEqual(3, journal.len);
    try testing.expectEqualStrings("Root.Servers.rpcServer", journal.lines[0]);
    try testing.expectEqualStrings("Root.Servers.httpServer", journal.lines[1]);
    try testing.expectEqualStrings("Root.Store", journal.lines[2]);
}
