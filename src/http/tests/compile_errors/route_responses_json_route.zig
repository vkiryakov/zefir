//! Must not compile: a body of its own for a 2xx status of a handler that
//! returns http.Json(T), whose value is that body.
const std = @import("std");
const http = @import("http");

const UserResponse = struct { id: u64 };
const Accepted = struct { job: []const u8 };

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{ .responses = .{ .ok = .{}, .created = .{ .json = Accepted } } }) },
    });

    pub fn create(_: *UsersV1Controller, _: *http.Context) !http.Json(UserResponse) {
        return .{ .value = .{ .id = 1 }, .status = 201 };
    }
};

test {
    var users: UsersV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend, .controllers = .{&users} });
    defer server.deinit(std.testing.io);
}
