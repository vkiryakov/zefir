//! Must not compile in Debug: the .query of a middleware's openapi names a
//! parameter, not the type of a DTO.
const std = @import("std");
const http = @import("http");

const PageQuery = struct { limit: u32 = 20 };

const Paging = struct {
    pub const openapi = .{ .query = "limit" };

    pub fn run(ctx: *http.Context) !http.MiddlewareResult {
        _ = try ctx.query(PageQuery);
        return .next;
    }
};

const UsersV1Controller = struct {
    pub const openapi = .{};

    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{ .middleware = .{Paging} }) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
