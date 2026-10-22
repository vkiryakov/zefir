//! Must not compile: the context of a stream reads the input of a route
//! that is not the stream's, one with a body.
const std = @import("std");
const http = @import("http");

const CreateUser = struct { name: []const u8 };

const UserEvent = union(enum) { joined: struct { id: u64 } };

const UsersV1Controller = struct {
    const Import = http.post("/import", .{ .body = CreateUser });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .events = http.sse.get("/events", .{ .events = UserEvent }) },
    });

    pub fn events(_: *UsersV1Controller, ctx: *http.sse.Context) !void {
        _ = try ctx.input(Import);
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
