//! Tests of the hooks: subscribers and interceptors, through the public
//! API.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const log = @import("../root.zig");
const testing = std.testing;

/// What a subscriber kept of one event; the event itself is only valid
/// during the call.
const Kept = struct {
    level: log.Level,
    scope: []const u8,
    message: []const u8,
    trace_id: ?[]const u8,
    span_id: ?[]const u8,
    line: []const u8,
    timestamp: std.Io.Timestamp,
};

/// A subscriber's context that keeps every event. Only its thread writes
/// it; read it after `unsubscribe` or `shutdown`, which wait for that
/// thread.
const Collector = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Kept) = .empty,
    /// The handler returns an error after it has kept the event.
    fail: bool = false,
    /// Set: the handler waits for `open` before it returns.
    gate: ?*std.atomic.Value(bool) = null,
    entered: std.atomic.Value(u32) = .init(0),

    fn init() Collector {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(c: *Collector) void {
        c.arena.deinit();
    }

    fn handler(context: ?*anyopaque, event: *const log.Event) anyerror!void {
        const c: *Collector = @ptrCast(@alignCast(context orelse return error.NoContext));
        _ = c.entered.fetchAdd(1, .seq_cst);
        if (c.gate) |open| while (!open.load(.seq_cst)) std.Thread.yield() catch {};
        const a = c.arena.allocator();
        try c.events.append(a, .{
            .level = event.level,
            .scope = try a.dupe(u8, event.scope),
            .message = try a.dupe(u8, event.message),
            .trace_id = if (event.trace_id) |id| try a.dupe(u8, id) else null,
            .span_id = if (event.span_id) |id| try a.dupe(u8, id) else null,
            .line = try a.dupe(u8, event.line),
            .timestamp = event.timestamp,
        });
        if (c.fail) return error.Boom;
    }

    /// Event `i`, or a test error.
    fn get(c: *const Collector, i: usize) !Kept {
        if (i >= c.events.items.len) return error.TestMissingEvent;
        return c.events.items[i];
    }
};

fn traced() !core.Context {
    return core.Context.root.withTrace(try core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"));
}

/// Line `n` (from 0) of `text`, without its '\n'.
fn lineAt(text: []const u8, n: usize) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (0..n) |_| _ = lines.next() orelse return error.TestMissingLine;
    return lines.next() orelse error.TestMissingLine;
}

test "a subscriber gets the records of its levels, as the output writes them" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .level = .debug, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{ .warn, .err }, .context = &c, .handler = Collector.handler });
    const handle = logger.scoped("db").withContext(try traced());
    handle.info("Connected", .{});
    handle.warn("Slow \"query\"", .{ .ms = 1200 });
    logger.err("Lost", .{ .code = 7 });
    logger.unsubscribe(id);

    try testing.expectEqual(@as(usize, 2), c.events.items.len);
    const warn = try c.get(0);
    try testing.expectEqual(log.Level.warn, warn.level);
    try testing.expectEqualStrings("db", warn.scope);
    try testing.expectEqualStrings("Slow \\\"query\\\"", warn.message);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", warn.trace_id orelse return error.TestNoTraceId);
    try testing.expectEqualStrings("00f067aa0ba902b7", warn.span_id orelse return error.TestNoSpanId);
    try testing.expectEqualStrings(try lineAt(out.written(), 1), warn.line);
    try testing.expect(warn.timestamp.nanoseconds > 0);
    const err = try c.get(1);
    try testing.expectEqual(log.Level.err, err.level);
    try testing.expectEqualStrings("", err.scope);
    try testing.expectEqualStrings("Lost", err.message);
    try testing.expect(err.trace_id == null);
    try testing.expectEqualStrings(try lineAt(out.written(), 2), err.line);
}

test "a subscriber with a scope gets that scope and its subscopes only" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.info}, .scope = "zefir.rpc", .context = &c, .handler = Collector.handler });
    logger.info("no scope", .{});
    logger.scoped("zefir.rpc").info("rpc", .{});
    logger.scoped("zefir.rpc.server").info("server", .{});
    logger.scoped("zefir.rpcx").info("other", .{});
    logger.unsubscribe(id);
    try testing.expectEqual(@as(usize, 2), c.events.items.len);
    try testing.expectEqualStrings("rpc", (try c.get(0)).message);
    try testing.expectEqualStrings("server", (try c.get(1)).message);
}

fn ignore(_: ?*anyopaque, _: *const log.Event) anyerror!void {}

test "subscribe refuses a ninth subscriber, a capacity that is not a power of two of at least 2, and an empty scope" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    try testing.expectError(error.CapacityNotPowerOfTwo, logger.subscribe(.{ .levels = &.{.err}, .capacity = 100, .handler = ignore }));
    try testing.expectError(error.CapacityTooSmall, logger.subscribe(.{ .levels = &.{.err}, .capacity = 1, .handler = ignore }));
    try testing.expectError(error.EmptyPrefix, logger.subscribe(.{ .levels = &.{.err}, .scope = "", .handler = ignore }));
    var ids: [8]log.SubscriptionId = undefined;
    for (&ids) |*id| id.* = try logger.subscribe(.{ .levels = &.{.err}, .capacity = 2, .handler = ignore });
    // Unsubscribing gives no slot back: the limit is over the logger's life.
    logger.unsubscribe(ids[0]);
    try testing.expectError(error.TooManySubscribers, logger.subscribe(.{ .levels = &.{.err}, .handler = ignore }));
    logger.unsubscribe(ids[0]); // a second time does nothing
}

test "only the levels of active subscribers are routed" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const levels = &logger.engine.registry.levels;
    try testing.expectEqual(@as(u8, 0), levels.load(.seq_cst));
    const first = try logger.subscribe(.{ .levels = &.{.err}, .handler = ignore });
    const second = try logger.subscribe(.{ .levels = &.{ .warn, .err }, .handler = ignore });
    try testing.expectEqual(@as(u8, 1 << @backingInt(log.Level.warn) | 1 << @backingInt(log.Level.err)), levels.load(.seq_cst));
    logger.unsubscribe(second);
    try testing.expectEqual(@as(u8, 1 << @backingInt(log.Level.err)), levels.load(.seq_cst));
    logger.unsubscribe(first);
    try testing.expectEqual(@as(u8, 0), levels.load(.seq_cst));
}

fn slowHandler(context: ?*anyopaque, event: *const log.Event) anyerror!void {
    testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    return Collector.handler(context, event);
}

test "unsubscribe waits until the subscriber has handled its queue; its handler is not called after that" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = slowHandler });
    for (0..3) |_| logger.err("queued", .{});
    logger.unsubscribe(id);
    try testing.expectEqual(@as(usize, 3), c.events.items.len);
    logger.err("after", .{});
    try testing.expectEqual(@as(usize, 3), c.events.items.len);
}

test "a full subscriber queue drops records into alert_dropped; handler errors count in alert_failures" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    c.fail = true;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .capacity = 2, .context = &c, .handler = Collector.handler });
    logger.err("held", .{}); // the handler takes it and waits
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    for (0..3) |_| logger.err("queued", .{}); // two fit, the third does not
    open.store(true, .seq_cst);
    logger.unsubscribe(id);
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.alert_dropped);
    try testing.expectEqual(@as(u64, 3), s.alert_failures);
    try testing.expectEqual(@as(usize, 3), c.events.items.len);
}

/// Logs an error record from inside the handler.
const Echo = struct {
    logger: log.Logger,
    calls: std.atomic.Value(u32) = .init(0),

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const e: *Echo = @ptrCast(@alignCast(context orelse return error.NoContext));
        _ = e.calls.fetchAdd(1, .seq_cst);
        e.logger.err("alert failed", .{});
    }
};

test "records logged by a handler go to the output, never back to subscribers" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &out.writer } });
        var echo: Echo = .{ .logger = logger };
        const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = Echo.handler });
        logger.err("disk full", .{});
        logger.unsubscribe(id);
        logger.deinit();
        try testing.expectEqual(@as(u32, 1), echo.calls.load(.seq_cst));
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
        try testing.expect(std.mem.find(u8, out.written(), "\"message\":\"alert failed\"") != null);
    }
}

test "shutdown waits until the subscribers have handled their queues" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = slowHandler });
    for (0..3) |_| logger.err("queued", .{});
    try logger.shutdown(.none);
    try testing.expectEqual(@as(usize, 3), c.events.items.len);
}

test "a shutdown that times out on a subscriber leaves it to deinit, which stops it after the record in hand" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    for (0..3) |_| logger.err("queued", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    const timed_out = logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } });
    const opener = try std.Thread.spawn(.{}, openOnAbandon, .{ &open, logger });
    logger.deinit();
    opener.join();
    try testing.expectError(error.Timeout, timed_out);
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
}

/// Opens `open` once `deinit` has told the logger's threads to drop what is
/// left; `deinit` waits for the handler that `open` holds, so the logger is
/// alive while this reads it.
fn openOnAbandon(open: *std.atomic.Value(bool), logger: log.Logger) void {
    while (!logger.engine.abandon.load(.seq_cst)) std.Thread.yield() catch {};
    open.store(true, .seq_cst);
}
