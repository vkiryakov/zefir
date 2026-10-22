//! Must not compile: an unknown field in a nested option.
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
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend.backend() }, .unknown_fields = .{ .bdy = .reject } });
    defer server.deinit(std.testing.io);
}
