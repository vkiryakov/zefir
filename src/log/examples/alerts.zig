//! zefir-log in queued mode, as a service runs it: an alert subscriber for
//! error records, an interceptor that drops health checks, the call site
//! of error records only, and a stop with a deadline.

const std = @import("std");
const core = @import("core");
const log = @import("log");

/// Where alerts go. A real handler posts `event.line` to a webhook or a
/// pager, with its own timeout: it runs on the subscriber's own thread, so
/// it may take its time. That thread is the logger's, not a task of a zio
/// runtime: post through `init.io`, which any thread may use. A failed post
/// is best returned, or logged by the handler itself: a task it hands the
/// post to logs like any caller, and its error record would come back as an
/// alert.
const Alerts = struct {
    sent: std.atomic.Value(u32) = .init(0),

    fn send(context: ?*anyopaque, event: *const log.Event) anyerror!void {
        const alerts: *Alerts = @ptrCast(@alignCast(context orelse return error.NoContext));
        _ = event; // a real handler posts event.line
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
        .mode = .{
            .queued = .{
                .capacity = 4096, // records the queue holds: a power of two, at least 2
                .batch_size = 128, // records per write
                .overflow = .drop_new, // or .block
            },
        },
        .source = .{ .default = .none, .err = .file_line }, // the call site of error records only
    });
    defer logger.deinit();

    var alerts: Alerts = .{};
    const subscription = try logger.subscribe(.{ .levels = &.{.err}, .context = &alerts, .handler = Alerts.send });
    try logger.use(.{ .filter = dropHealthChecks });

    logger.scoped("http.health").info("GET /health", .{ .status = 200 }); // dropped
    const orders = logger.scoped("orders");
    orders.info("Order placed", .{ .src = @src(), .order_id = 7, .total_cents = 4200 });
    orders.err("Payment declined", .{ .src = @src(), .order_id = 7, .reason = "card_expired" });

    logger.unsubscribe(subscription); // returns once the alert is handled

    // Stop: write what is queued, for five seconds at most.
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(init.io), .fromSeconds(5));
    logger.shutdown(deadline.toTimeout()) catch |e| switch (e) {
        error.Timeout => std.debug.print("log: {d} records not written\n", .{logger.stats().pending}),
    };
    std.debug.print("alerts sent: {d}, records filtered: {d}\n", .{ alerts.sent.load(.monotonic), logger.stats().filtered });
}
