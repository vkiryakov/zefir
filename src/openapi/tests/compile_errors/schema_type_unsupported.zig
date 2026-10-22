//! Must not compile: a field of a response whose type has no JSON Schema.
const zefir = @import("zefir");
const http = zefir.http;

const Reading = struct { value: f128 };
const SensorsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/sensors",
        .methods = .{ .read = http.get("/{id}", .{}) },
    });

    pub const openapi: zefir.openapi.ControllerDoc(@This()) = .{ .routes = .{ .read = .{ .summary = "Read a sensor" } } };

    pub fn read(_: *SensorsController, _: *http.Context) error{}!http.Json(Reading) {
        return .{ .value = .{ .value = 1.5 } };
    }
};

var sensors: SensorsController = .{};

test {
    _ = comptime zefir.openapi.document(@TypeOf(.{ .controllers = .{&sensors} }), .{ .info = .{ .title = "Todos API", .version = "1.0.0" } });
}
