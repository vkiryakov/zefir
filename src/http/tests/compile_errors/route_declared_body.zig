//! Must not compile: a declared JSON body with a field of a type that JSON
//! does not give: the check of ctx.json, at the declaration.
const std = @import("std");
const http = @import("http");

const CreateRequest = struct {
    name: []const u8,
    codes: [3]u8,
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{ .body = CreateRequest }) },
    });

    pub fn create(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
