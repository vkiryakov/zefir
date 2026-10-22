//! Must not compile: mapError gives an error of a route a status that is
//! not a final status of HTTP; the server would answer 500 instead.
const zefir = @import("zefir");
const http = zefir.http;

const TeapotsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/teapots",
        .methods = .{ .brew = http.post("", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .brew = .{ .summary = "Brew tea" } } };

    pub fn brew(_: *TeapotsController, _: *http.Context) error{Teapot}!void {
        return error.Teapot;
    }
};

const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
        return switch (err) {
            error.Teapot => .{ .status = 600, .body = .{ .title = "A teapot", .status = 600, .code = "teapots.teapot" } },
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }
};

var teapots: TeapotsController = .{};
var app_errors: AppErrors = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&teapots}, .error_handler = &app_errors }), .{ .info = .{ .title = "Teapots API", .version = "1.0.0" } });
}
