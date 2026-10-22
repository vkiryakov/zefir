//! Must not compile: a declared query with a struct field, which only JSON
//! gives: the check of ctx.query, at the declaration.
const std = @import("std");
const http = @import("http");

const Filter = struct { done: bool };

const Query = struct {
    page: u32 = 1,
    filter: Filter,
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .list = http.get("", .{ .query = Query }) },
    });

    pub fn list(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
