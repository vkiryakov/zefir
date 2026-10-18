//! Must not compile: an error of the application without an error handler,
//! which gives it 500 (the strict error check).
const std = @import("std");
const http = @import("http");

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{}) },
    });

    pub fn create(_: *UsersV1Controller, ctx: *http.Context) !void {
        if (ctx.request.header("x-full") != null) return error.UserLimitReached;
        if (ctx.request.header("x-missing") != null) return error.UserNotFound;
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
