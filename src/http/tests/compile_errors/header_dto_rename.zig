//! Must not compile: v.rename in a DTO of headers, whose fields name their
//! headers by a rule of their own.
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const Headers = struct {
    request_id: ?[]const u8 = null,

    pub const field_rules = .{ .request_id = .{ v.rename("requestId"), v.trim } };
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, ctx: *http.Context) !void {
        _ = try ctx.headers(Headers);
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
