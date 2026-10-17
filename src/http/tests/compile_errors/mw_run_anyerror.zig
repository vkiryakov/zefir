//! Must not compile: a run of a controller's middleware returns anyerror,
//! which the strict error check cannot read.
const std = @import("std");
const http = @import("http");

fn requireUser(ctx: *http.Context) anyerror!http.MiddlewareResult {
    if (ctx.request.header("authorization") == null) return error.Unauthenticated;
    return .next;
}

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .middleware = .{requireUser},
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
