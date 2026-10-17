//! Must not compile: a field of a JSON DTO of a type that JSON does not
//! give.
const std = @import("std");
const http = @import("http");

const Item = struct { codes: [3]u8 };

const CreateRequest = struct {
    name: []const u8,
    items: []const Item,
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{}) },
    });

    pub fn create(_: *UsersV1Controller, ctx: *http.Context) !void {
        _ = try ctx.json(CreateRequest);
    }
};

test {
    var users: UsersV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
