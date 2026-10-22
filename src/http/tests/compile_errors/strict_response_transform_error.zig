//! Must not compile: the error of a transform of the response value, which
//! the error handler gives 500 through .fallback (the strict error check).
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const UserResponse = struct {
    display_name: []const u8,

    pub const field_rules = .{ .display_name = v.transformWith(checkName) };
};

fn checkName(_: std.mem.Allocator, name: []const u8) error{BadDisplayName}![]const u8 {
    if (name.len == 0) return error.BadDisplayName;
    return name;
}

const ApiError = struct { code: []const u8 };

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.UserNotFound => .{ .status = 404, .body = .{ .code = "users.not_found" } },
            else => .fallback(err, .{ .code = http.defaultCode(err) }),
        };
    }
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !http.Json(UserResponse) {
        return .{ .value = .{ .display_name = "Ann" } };
    }
};

test {
    var users: UsersV1Controller = .{};
    var app_errors: AppErrors = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&users}, .error_handler = &app_errors }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(std.testing.io);
}
