//! Must not compile: an object in the server's middleware with none of
//! the phases.
const std = @import("std");
const http = @import("http");

const Empty = struct {
    hits: u32 = 0,
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var empty: Empty = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users}, .middleware = .{&empty} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
