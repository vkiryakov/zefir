//! zefir-log in queued mode, as a service runs it: an alert subscriber for
//! error records, an interceptor that drops health checks, and a shutdown
//! with a deadline. `zig build test` runs it; it fails if the alert or the
//! interceptor did not work.

const std = @import("std");
const core = @import("core");
const log = @import("log");

/// Where alerts go. A real handler posts `event.line` to a webhook or a
/// pager, with its own timeout: it runs on the subscriber's own thread, so
/// it may take its time.
const Alerts = struct {
    sent: std.atomic.Value(u32) = .init(0),

    fn send(context: ?*anyopaque, event: *const log.Event) anyerror!void {
        const alerts: *Alerts = @ptrCast(@alignCast(context orelse return error.NoContext));
        if (event.level != .err) return error.UnexpectedLevel;
        _ = alerts.sent.fetchAdd(1, .monotonic);
    }
};

/// Health checks would flood the log: drop them before they are written.
fn dropHealthChecks(_: ?*anyopaque, event: *const log.Event) bool {
    return !std.mem.eql(u8, event.scope, "http.health");
}

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "orders", .version = "3.0.0" },
        .mode = .{ .queued = .{} },
    });
    defer logger.deinit();

    var alerts: Alerts = .{};
    const subscription = try logger.subscribe(.{ .levels = &.{.err}, .context = &alerts, .handler = Alerts.send });
    try logger.use(.{ .filter = dropHealthChecks });

    logger.scoped("http.health").info("GET /health", .{ .status = 200 }); // dropped
    const orders = logger.scoped("orders");
    orders.info("Order placed", .{ .order_id = 7, .total_cents = 4200 });
    orders.err("Payment declined", .{ .order_id = 7, .reason = "card_expired" });

    logger.unsubscribe(subscription); // returns once the alert is handled
    if (alerts.sent.load(.monotonic) != 1) return error.AlertMissed;
    if (logger.stats().filtered != 1) return error.HealthCheckWritten;

    // Stop: write what is queued, for two seconds at most.
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(init.io), .fromSeconds(2));
    logger.shutdown(deadline.toTimeout()) catch |e| switch (e) {
        error.Timeout => std.debug.print("log: {d} records not written\n", .{logger.stats().pending}),
    };
}
