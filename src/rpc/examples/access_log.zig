//! Access logs on both sides of the users service: `rpc_log.AccessLog`
//! first in the server's chain, `rpc_log.ClientAccessLog` first in the
//! client's, each writing one record per call. The calls come from a
//! gateway that got a W3C traceparent, so the records of both sides carry
//! its trace id.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const rpc_log = @import("rpc-log");
const api = @import("users-api");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    const app = logger.scoped("app");

    var repo: UserRepository = .init(gpa);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };

    // A record per call that reaches the server's chain, with the values
    // of x-tenant; never a body or credentials.
    var access_log: rpc_log.AccessLog = .init(logger.scoped("rpc"), .{ .metadata_keys = &.{"x-tenant"} });
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var server = try rpc.Server.init(gpa, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        // First in the chain, it sees the outcome of every link after it.
        .middleware = .{&access_log},
    });
    defer server.deinit(io);
    try server.start(io);

    var client_log: rpc_log.ClientAccessLog = .init(logger.scoped("rpc.client"), .{});
    var client = try rpc.Client.init(gpa, .{
        .transport = memory.clientTransport(),
        .middleware = .{&client_log},
    });
    defer client.deinit();

    // The trace of the request the gateway got, from its traceparent header.
    const trace = try core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    const ctx = core.Context.root.withTrace(trace);
    const tenant: []const rpc.Metadata.Entry = &.{.{ .key = "x-tenant", .value = "acme" }};

    var created = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{ .metadata = tenant });
    defer created.deinit();
    var missing = try client.call(io, ctx, api.UserApi.getUser, .{ .id = 42 }, .{ .metadata = tenant });
    defer missing.deinit();
    // Against the rules of CreateUserRequest, so never sent: neither log
    // has a record of it.
    var invalid = try client.call(io, ctx, api.UserApi.createUser, .{ .name = "", .email = "ada@example.com" }, .{});
    defer invalid.deinit();

    // After the stop the call has no response: the client's record names
    // its error.
    try server.shutdown(io);
    var late = client.call(io, ctx, api.UserApi.getUser, .{ .id = 1 }, .{}) catch |err| {
        app.warn("Call failed", .{ .reason = err });
        return;
    };
    late.deinit();
}
