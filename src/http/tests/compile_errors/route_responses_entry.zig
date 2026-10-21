//! Must not compile: an entry of .responses with a key other than
//! .content_type and .json.
const std = @import("std");
const http = @import("http");

const UserResponse = struct { id: u64 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{ .responses = .{ .created = .{ .schema = UserResponse } } }) },
    });

    pub fn create(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
