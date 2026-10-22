//! Must not compile: a body on an SSE route, whose request has none.
const std = @import("std");
const http = @import("http");

const Filter = struct { tag: []const u8 };

const UserEvent = union(enum) { joined: struct { id: u64 } };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .events = http.sse.get("/events", .{ .events = UserEvent, .body = Filter }) },
    });

    pub fn events(_: *UsersV1Controller, _: *http.sse.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
