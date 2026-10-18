//! Must not compile: a pointer to an object in the middleware of a
//! controller; only the server's middleware takes one.
const std = @import("std");
const http = @import("http");

const AuditLog = struct {
    pub fn onFinish(_: *AuditLog, _: *http.Context, _: http.Outcome) !void {}
};

var audit_log: AuditLog = .{};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .middleware = .{&audit_log},
        .methods = .{ .list = http.get("", .{}) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
