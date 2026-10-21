//! Must not compile: a body on an SSE route, whose request has none.
const std = @import("std");
const http = @import("http");

const Filter = struct { tag: []const u8 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .events = http.sse.get("/events", .{ .body = Filter }) },
    });

    pub fn events(_: *UsersV1Controller, _: *http.sse.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
