//! Must not compile: a route that declares a JSON body and a form body.
const std = @import("std");
const http = @import("http");

const CreateUser = struct { name: []const u8 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{ .body = CreateUser, .form = CreateUser }) },
    });

    pub fn create(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
