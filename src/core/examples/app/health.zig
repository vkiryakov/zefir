//! The health checks of the shop, for the load balancer and Kubernetes:
//! /livez says the process runs, /readyz whether it takes work.

const zefir = @import("zefir");
const http = zefir.http;

pub const HealthController = struct {
    /// A built-in dependency: the state of App, read-only.
    status: *const zefir.app.Status,

    pub const http_routes = http.routes(.{ .methods = .{
        .live = http.get("/livez", .{}),
        .ready = http.get("/readyz", .{}),
    } });

    pub const Health = struct { status: []const u8 };

    pub fn live(_: *HealthController, _: *http.Context) !http.Json(Health) {
        return .{ .value = .{ .status = "ok" } };
    }

    /// 503 until App has started everything, and from the first step of its
    /// stop on.
    pub fn ready(self: *HealthController, _: *http.Context) !http.Json(Health) {
        if (!self.status.isReady()) return .{ .value = .{ .status = "not ready" }, .status = 503 };
        return .{ .value = .{ .status = "ok" } };
    }
};
