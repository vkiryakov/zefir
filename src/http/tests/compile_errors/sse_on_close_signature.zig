//! Must not compile: an .on_close of another form.
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .events = http.sse.get("/events", .{ .on_close = .closed }) },
    });

    pub fn events(_: *UsersV1Controller, _: *http.sse.Context) !void {}
    pub fn closed(_: *UsersV1Controller, _: *http.sse.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
