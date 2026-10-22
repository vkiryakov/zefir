//! Must not compile: a field of the route's .path, required, that its
//! pattern does not name.
const std = @import("std");
const http = @import("http");

const UserPath = struct { id: u64 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{ .path = UserPath }) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
