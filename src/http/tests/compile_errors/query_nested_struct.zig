//! Must not compile: a struct field in a DTO of the query, which holds
//! strings.
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
        .methods = .{ .list = http.get("", .{}) },
    });

    pub fn list(_: *UsersV1Controller, ctx: *http.Context) !void {
        _ = try ctx.query(Query);
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
