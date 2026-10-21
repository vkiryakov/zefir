//! Must not compile: a parameter of the route's pattern that no field of
//! its .path reads.
const std = @import("std");
const http = @import("http");

const UserPath = struct { user_id: u64 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{ .path = UserPath }) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
