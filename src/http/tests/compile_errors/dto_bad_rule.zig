//! Must not compile: a rule that does not fit its field, in a DTO of the
//! path; the error is the validator's own.
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const IdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.maxLength(10) };
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, ctx: *http.Context) !void {
        _ = try ctx.path(IdPath);
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
