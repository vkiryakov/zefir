//! Must not compile: the run of an object in the server's middleware
//! without its self.
const std = @import("std");
const http = @import("http");

const Timing = struct {
    pub fn run(ctx: *http.Context) !http.MiddlewareResult {
        _ = ctx;
        return .next;
    }
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{}) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var timing: Timing = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users}, .middleware = .{&timing} });
    defer server.deinit(std.testing.io);
}
