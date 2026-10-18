//! Must not compile: a mapError that takes a context, which the strict
//! error check could not call at compile time.
const std = @import("std");
const http = @import("http");

const ApiError = struct { code: []const u8 };

const AppErrors = struct {
    pub fn mapError(_: *http.Context, err: anyerror) http.ErrorResponse(ApiError) {
        return .fallback(err, .{ .code = http.defaultCode(err) });
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
