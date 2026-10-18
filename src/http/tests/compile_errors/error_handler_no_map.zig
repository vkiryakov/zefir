//! Must not compile: an error handler without mapError.
const std = @import("std");
const http = @import("http");

const ApiError = struct { code: []const u8 };

const AppErrors = struct {
    pub fn handle(_: *AppErrors, _: *http.Context, _: anyerror, _: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        return .respond;
    }
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .get = http.get("/{id}", .{}) },
    });

    pub fn get(_: *UsersV1Controller, _: *http.Context) !void {}
};

test {
    var users: UsersV1Controller = .{};
    var app_errors: AppErrors = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users}, .error_handler = &app_errors });
    defer server.deinit(std.testing.io);
}
