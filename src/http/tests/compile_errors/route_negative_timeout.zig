//! Must not compile: a route's .timeout below zero, known at compile time.
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(-5) }) },
    });

    pub fn exportCsv(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
