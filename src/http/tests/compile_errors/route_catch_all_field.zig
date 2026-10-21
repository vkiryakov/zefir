//! Must not compile: the rest of the path, {*path}, read by a field that
//! is not a string.
const std = @import("std");
const http = @import("http");

const FilePath = struct { path: u32 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/files",
        .methods = .{ .files = http.get("/{*path}", .{ .path = FilePath }) },
    });

    pub fn files(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
