const std = @import("std");
const log = @import("log");

/// Kubernetes asks GET /health every few seconds: these records are noise.
fn dropHealthChecks(_: ?*anyopaque, event: *const log.Event) bool {
    return !std.mem.eql(u8, event.scope, "http.health"); // false drops the record
}

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "orders", .version = "3.0.0" },
    });
    defer logger.deinit();
    try logger.use(.{ .filter = dropHealthChecks });

    const health = logger.scoped("http.health");
    const orders = logger.scoped("orders");
    health.info("GET /health", .{ .status = 200 });
    orders.info("Order placed", .{ .order_id = 7, .total_cents = 4200 });
    health.info("GET /health", .{ .status = 200 });

    std.debug.print("filtered: {d}\n", .{logger.stats().filtered});
}
