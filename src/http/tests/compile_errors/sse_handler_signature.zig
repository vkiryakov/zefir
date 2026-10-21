//! Must not compile: an SSE handler that takes the context of a request.
const std = @import("std");
const http = @import("http");

const UserEvent = union(enum) { joined: struct { id: u64 } };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .events = http.sse.get("/events", .{ .events = UserEvent }) },
    });

    pub fn events(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
