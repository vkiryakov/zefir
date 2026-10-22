//! zefir.App with NATS: the client of NATS, the transport of rpc on it, an
//! rpc server and a client of it, all beans of one App, against live
//! servers. A call goes through the broker and the stop drains everything
//! in order; a broker that goes away for good stops the App by itself.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const nats = @import("nats");
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const root = @import("root.zig");
const services = @import("services.zig");

const servers = root.servers;

/// What the factory of the client of NATS reads.
const Config = struct {
    url: []const u8,
    reconnect: nats.ReconnectOptions = services.fast_reconnect,
};

const Root = struct {
    pub const module: core.app.Module = .{
        .handlers = &.{services.Users},
        .factories = &.{ Nats, Servers },
        .values = &.{*const Config},
    };

    pub const Nats = struct {
        pub fn natsClient(gpa: std.mem.Allocator, io: Io, config: *const Config) !nats.Client {
            return .init(gpa, io, .{ .servers = &.{config.url}, .name = "zefir-e2e-app", .reconnect = config.reconnect });
        }

        pub fn bus(gpa: std.mem.Allocator, client: *nats.Client) !rpc_nats.Transport {
            return .init(gpa, client, .{});
        }
    };

    pub const Servers = struct {
        pub fn rpcServer(gpa: std.mem.Allocator, transport: *rpc_nats.Transport, handlers: core.app.Handlers(Root)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = transport.serverTransport() });
        }

        pub fn usersClient(gpa: std.mem.Allocator, transport: *rpc_nats.Transport) !rpc.Client {
            return .init(gpa, .{}, .{ .transport = transport.clientTransport() });
        }
    };
};

fn callThenStop(io: Io) !void {
    const config: Config = .{ .url = servers.plain };
    var app = try core.App(Root).init(testing.allocator, io, .{&config}, .{});
    defer app.deinit();
    try app.start();
    try testing.expect(app.isReady());

    const client: *rpc.Client = app.get(rpc.Client);
    var found = try client.call(io, .root, services.UserApi.getUser, .{ .id = 1 }, .{});
    defer found.deinit();
    try testing.expectEqualStrings("Alex", found.outcome.ok.name);

    app.requestStop();
    try app.wait();
    try testing.expectEqual(core.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
    // The client of NATS was drained after the server.
    try testing.expectEqual(nats.CloseReason.drained, app.get(nats.Client).close_reason.?);
}

test "App with NATS: a call through NATS, then a graceful stop" {
    try root.onZio(callThenStop);
}

fn goneForGood(io: Io) !void {
    // One failed attempt to reconnect, and the client gives up.
    var reconnect = services.fast_reconnect;
    reconnect.max_attempts = 1;
    const config: Config = .{ .url = servers.restart, .reconnect = reconnect };
    var app = try core.App(Root).init(testing.allocator, io, .{&config}, .{});
    defer app.deinit();
    try app.start();
    {
        var found = try app.get(rpc.Client).call(io, .root, services.UserApi.getUser, .{ .id = 1 }, .{});
        found.deinit();
    }

    try root.stop(io, servers.restart_container);
    // Started again, whatever happens below.
    defer root.start(io, servers.restart_container) catch |err| std.debug.print("the restart server did not start again: {t}\n", .{err});
    // The client gives up and closes, and the server's subscriptions end
    // with it: whichever tells App first is the cause.
    const result = app.wait();
    const failure = app.failure() orelse return error.TestNoFailure;
    try testing.expectEqual(core.app.Failure.Step.wait, failure.step);
    if (std.mem.eql(u8, failure.bean, "Root.Nats.natsClient")) {
        try testing.expectError(error.ReconnectFailed, result);
    } else if (std.mem.eql(u8, failure.bean, "Root.Servers.rpcServer")) {
        try testing.expectError(error.Unavailable, result);
    } else {
        std.debug.print("unexpected failure of {s}: {t}\n", .{ failure.bean, failure.err });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(core.app.State.stopped, app.state());
}

test "NATS that goes away for good stops the App" {
    try root.onZio(goneForGood);
}
