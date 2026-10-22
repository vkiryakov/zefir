//! Must not compile: a misspelled option of a route.
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .methods = .{ .get = http.get("/x", .{ .timout = std.Io.Duration.fromSeconds(5) }) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
