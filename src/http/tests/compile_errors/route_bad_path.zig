//! Must not compile: a route path without its leading slash.
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .methods = .{ .get = http.get("users", .{}) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
