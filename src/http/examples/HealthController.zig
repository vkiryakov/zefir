//! GET /api/health, for the load balancer: a service route without a
//! version, open to everybody, since it lists no requireUser.

const http = @import("http");

const HealthController = @This();

pub const http_routes = http.routes(.{
    .methods = .{ .check = http.get("/health", .{}) },
});

pub const Health = struct { status: []const u8 };

pub fn check(_: *HealthController, _: *http.Context) !http.Json(Health) {
    return .{ .value = .{ .status = "ok" } };
}
