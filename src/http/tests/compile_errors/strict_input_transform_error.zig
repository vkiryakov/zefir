//! Must not compile: the error of a transform of the input, which the
//! error handler gives 500 through .fallback (the strict error check).
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const SearchQuery = struct {
    tags: []const []const u8 = &.{},

    pub const field_rules = .{ .tags = v.transformWith(limitTags) };
};

fn limitTags(_: std.mem.Allocator, tags: []const []const u8) error{TooManyTags}![]const []const u8 {
    if (tags.len > 10) return error.TooManyTags;
    return tags;
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
        .methods = .{ .search = http.get("", .{}) },
    });

    pub fn search(_: *UsersV1Controller, ctx: *http.Context) !void {
        _ = try ctx.query(SearchQuery);
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
