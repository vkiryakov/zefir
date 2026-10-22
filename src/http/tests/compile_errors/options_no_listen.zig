//! Must not compile: options of Server.init without .listen, which has no
//! default.
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .prefix = "/api" });
    defer server.deinit(std.testing.io);
}
