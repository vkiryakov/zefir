//! Must not compile: a declared DTO of headers with v.rename, whose fields
//! name their headers by a rule of their own: the check of ctx.headers, at
//! the declaration.
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const Headers = struct {
    request_id: ?[]const u8 = null,

    pub const field_rules = .{ .request_id = v.rename("requestId") };
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{ .headers = Headers }) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
