//! Must not compile: one status and media type with two schemas.
const zefir = @import("zefir");
const http = zefir.http;

const ApiError = struct { code: []const u8 };
const Slowdown = struct { retry_after: u32 };

/// Answers 429 itself, with a body of its own.
const Limiter = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .responses = .{ .too_many_requests = .{ .json = Slowdown } } };

    pub fn run(_: *http.Context) error{RateLimited}!http.MiddlewareResult {
        return .next;
    }
};

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return .fallback(err, .{ .code = http.defaultCode(err) });
    }
};
const ItemsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/items",
        .methods = .{ .list = http.get("", .{ .middleware = .{Limiter} }) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List items" } } };

    pub fn list(_: *ItemsController, _: *http.Context) error{}!void {}
};

var items: ItemsController = .{};
var app_errors: AppErrors = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&items}, .error_handler = &app_errors }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
