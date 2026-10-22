//! Must not compile: an element of the server's middleware of no kind it
//! takes.
const std = @import("std");
const http = @import("http");

fn requestId(ctx: *http.Context) !http.MiddlewareResult {
    try ctx.response.setHeader("x-request-id", ctx.requestId());
    return .next;
}

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users}, .middleware = .{ requestId, 1 } }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
