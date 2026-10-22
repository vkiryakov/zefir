//! Must not compile: a method's middleware names a field the controller
//! does not have.
const std = @import("std");
const http = @import("http");

const Audit = struct {
    pub fn onFinish(_: *Audit, _: *http.Context, _: http.Outcome) !void {}
};

fn requireAdmin(ctx: *http.Context) !http.MiddlewareResult {
    if (ctx.request.header("x-admin") == null) return error.PermissionDenied;
    return .next;
}

const UsersV1Controller = struct {
    audit: *Audit,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .delete = http.delete("/{id}", .{ .middleware = .{ requireAdmin, .audt } }) },
    });

    pub fn delete(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var audit: Audit = .{};
    var users: UsersV1Controller = .{ .audit = &audit };
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
