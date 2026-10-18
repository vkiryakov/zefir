//! Must not compile: an else without .fallback, which gives the errors of
//! the framework it does not name 500 (the strict error check).
const std = @import("std");
const http = @import("http");

const ApiError = struct { code: []const u8 };

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.InvalidRequest => .{ .status = 400, .body = .{ .code = "bad_request" } },
            error.Unauthenticated => .{ .status = 401, .body = .{ .code = "unauthenticated" } },
            error.PermissionDenied => .{ .status = 403, .body = .{ .code = "forbidden" } },
            error.UserNotFound => .{ .status = 404, .body = .{ .code = "users.not_found" } },
            else => .{ .status = 500, .body = .{ .code = "internal" } },
        };
    }
};

const UsersV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/users",
        .methods = .{ .create = http.post("", .{}) },
    });

    pub fn create(_: *UsersV1Controller, ctx: *http.Context) !void {
        if (ctx.request.header("x-full") != null) return error.UserLimitReached;
        if (ctx.request.header("x-missing") != null) return error.UserNotFound;
    }
};

test {
    var users: UsersV1Controller = .{};
    var app_errors: AppErrors = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&users}, .error_handler = &app_errors });
    defer server.deinit(std.testing.io);
}
