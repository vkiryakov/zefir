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
    /// Handler calls that have finished.
    done: std.atomic.Value(u32) = .init(0),

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
        _ = c.done.fetchAdd(1, .seq_cst);
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

/// A writer that holds the writer thread inside its first write until
/// `open` is set, and throws everything away.
const Held = struct {
    entered: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const held: *Held = @alignCast(@fieldParentPtr("writer", w));
        held.entered.store(true, .seq_cst);
        while (!held.open.load(.seq_cst)) std.Thread.yield() catch {};
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        return n + data[data.len - 1].len * splat;
    }

    fn waitEntered(held: *Held) void {
        while (!held.entered.load(.seq_cst)) std.Thread.yield() catch {};
    }
};

test "an error record reaches the subscribers even when the queue refuses it" {
    var held: Held = .{};
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1 } },
        .output = .{ .writer = &held.writer },
    });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    logger.info("held", .{});
    held.waitEntered();
    for (0..2) |_| logger.info("queued", .{});
    logger.err("Database unavailable", .{});
    held.open.store(true, .seq_cst);
    logger.unsubscribe(id);
    try testing.expectEqual(@as(u64, 1), logger.stats().dropped.err);
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
    try testing.expectEqualStrings("Database unavailable", (try c.get(0)).message);
}

test "an error record reaches the subscribers when stdout is closed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the test needs POSIX pipes
    const io = testing.io;
    const stdout_pipe = try std.Io.Threaded.pipe2(.{});
    const stderr_pipe = try std.Io.Threaded.pipe2(.{});
    const stdout_write: std.Io.File = .{ .handle = stdout_pipe[1], .flags = .{ .nonblocking = false } };
    const stderr_read: std.Io.File = .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } };
    const stderr_write: std.Io.File = .{ .handle = stderr_pipe[1], .flags = .{ .nonblocking = false } };
    defer stdout_write.close(io);
    defer stderr_read.close(io);
    defer stderr_write.close(io);
    (std.Io.File{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } }).close(io); // nobody reads stdout
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, io, .{});
    defer logger.deinit();
    logger.engine.stdout = stdout_write;
    logger.engine.stderr = stderr_write;
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    logger.err("first", .{}); // finds stdout closed
    logger.err("second", .{}); // stdout is known dead: only the subscriber takes it
    logger.info("third", .{}); // nobody takes it
    logger.unsubscribe(id);
    try testing.expectEqual(@as(usize, 2), c.events.items.len);
    try testing.expectEqualStrings("second", (try c.get(1)).message);
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 0), s.written);
    try testing.expectEqual(@as(u64, 3), s.dropped.write_failed);
}

test "after shutdown nothing reaches the subscribers, and subscribe is refused" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    try logger.shutdown(.none);
    logger.err("late", .{});
    try testing.expectEqual(@as(usize, 0), c.events.items.len);
    try testing.expectError(error.ShutDown, logger.subscribe(.{ .levels = &.{.err}, .handler = ignore }));
}

/// An interceptor that keeps the messages it sees and drops "drop me".
const Gatekeeper = struct {
    seen: [8][]const u8 = undefined,
    count: usize = 0,

    fn filter(context: ?*anyopaque, event: *const log.Event) bool {
        const g: *Gatekeeper = @ptrCast(@alignCast(context orelse return true));
        if (g.count < g.seen.len) {
            g.seen[g.count] = event.message;
            g.count += 1;
        }
        return !std.mem.eql(u8, event.message, "drop me");
    }
};

test "interceptors see each record once encoded, in the order they were added; false drops it everywhere" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Collector = .init();
    defer c.deinit();
    var first: Gatekeeper = .{};
    var second: Gatekeeper = .{};
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.info}, .context = &c, .handler = Collector.handler });
    try logger.use(.{ .context = &first, .filter = Gatekeeper.filter });
    try logger.use(.{ .context = &second, .filter = Gatekeeper.filter });
    logger.info("keep me", .{});
    logger.info("drop me", .{});
    logger.unsubscribe(id);
    try testing.expectEqual(@as(usize, 2), first.count);
    try testing.expectEqual(@as(usize, 1), second.count); // the first one dropped the second record
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));
    try testing.expect(std.mem.find(u8, out.written(), "keep me") != null);
    const s = logger.stats();
    try testing.expectEqual(@as(u64, 1), s.filtered);
    try testing.expectEqual(@as(u64, 2), s.accepted);
}

/// An interceptor that logs, which it must not.
const Chatty = struct {
    logger: log.Logger,

    fn filter(context: ?*anyopaque, _: *const log.Event) bool {
        const chatty: *Chatty = @ptrCast(@alignCast(context orelse return true));
        chatty.logger.info("from an interceptor", .{});
        return true;
    }
};

test "a record logged from an interceptor is dropped and counted in hook_errors" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    var chatty: Chatty = .{ .logger = logger };
    try logger.use(.{ .context = &chatty, .filter = Chatty.filter });
    logger.info("record", .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(u64, 1), logger.stats().hook_errors);
}

fn keepAll(_: ?*anyopaque, _: *const log.Event) bool {
    return true;
}

test "use refuses a ninth interceptor" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    for (0..8) |_| try logger.use(.{ .filter = keepAll });
    try testing.expectError(error.TooManyInterceptors, logger.use(.{ .filter = keepAll }));
}

test "with subscribers and interceptors, logging still never allocates" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(failing.allocator(), testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{ .info, .err }, .scope = "app", .handler = ignore });
    try logger.use(.{ .filter = keepAll });
    failing.fail_index = failing.alloc_index; // every allocation from here on fails
    const before = failing.allocations;
    const handle = logger.scoped("app.db").withContext(try traced());
    handle.info("query", .{ .ms = 3 });
    handle.err("lost", .{ .code = 7 });
    logger.warn("elsewhere", .{});
    try logger.flush(.none);
    logger.unsubscribe(id);
    try testing.expectEqual(before, failing.allocations);
}

fn unsubscribeThenCheck(logger: log.Logger, id: log.SubscriptionId, c: *const Collector, after_handler: *std.atomic.Value(u32)) void {
    logger.unsubscribe(id);
    if (c.done.load(.seq_cst) == 1) _ = after_handler.fetchAdd(1, .seq_cst);
}

test "two unsubscribes at once both return after the handler's call is over" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    logger.err("held", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    var after_handler: std.atomic.Value(u32) = .init(0);
    const first = try std.Thread.spawn(.{}, unsubscribeThenCheck, .{ logger, id, &c, &after_handler });
    const second = try std.Thread.spawn(.{}, unsubscribeThenCheck, .{ logger, id, &c, &after_handler });
    try testing.io.sleep(.fromMilliseconds(20), .awake); // both are inside unsubscribe by now
    open.store(true, .seq_cst);
    first.join();
    second.join();
    try testing.expectEqual(@as(u32, 2), after_handler.load(.seq_cst));
}

fn unsubscribeAndMark(logger: log.Logger, id: log.SubscriptionId, finished: *std.atomic.Value(bool)) void {
    logger.unsubscribe(id);
    finished.store(true, .seq_cst);
}

test "removing an idle subscriber does not wait for another subscriber's handler" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var busy: Collector = .init();
    defer busy.deinit();
    busy.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const busy_id = try logger.subscribe(.{ .levels = &.{.err}, .context = &busy, .handler = Collector.handler });
    const idle_id = try logger.subscribe(.{ .levels = &.{.warn}, .handler = ignore });
    logger.err("held", .{});
    while (busy.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    var busy_gone: std.atomic.Value(bool) = .init(false);
    var idle_gone: std.atomic.Value(bool) = .init(false);
    const remover = try std.Thread.spawn(.{}, unsubscribeAndMark, .{ logger, busy_id, &busy_gone });
    try testing.io.sleep(.fromMilliseconds(20), .awake); // the remover waits for the held handler
    const idle_remover = try std.Thread.spawn(.{}, unsubscribeAndMark, .{ logger, idle_id, &idle_gone });
    var waited: usize = 0;
    while (!idle_gone.load(.seq_cst) and waited < 2000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    const idle_first = idle_gone.load(.seq_cst) and !busy_gone.load(.seq_cst);
    open.store(true, .seq_cst);
    remover.join();
    idle_remover.join();
    try testing.expect(idle_first);
}

test "after a shutdown that timed out, unsubscribe waits only for the call in hand" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    for (0..4) |_| logger.err("alert", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try testing.expectError(error.Timeout, logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }));
    const opener = try std.Thread.spawn(.{}, openOnUnsubscribe, .{ &open, logger });
    logger.unsubscribe(id);
    opener.join();
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
}

/// Opens `open` once `unsubscribe` has begun removing the first
/// subscriber; `unsubscribe` waits for the handler that `open` holds.
fn openOnUnsubscribe(open: *std.atomic.Value(bool), logger: log.Logger) void {
    while (logger.engine.registry.subscribers[0].active.load(.seq_cst)) std.Thread.yield() catch {};
    open.store(true, .seq_cst);
}

/// Logs a warning from its handler once `open` is set.
const LateEcho = struct {
    logger: log.Logger,
    open: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const e: *LateEcho = @ptrCast(@alignCast(context orelse return error.NoContext));
        e.entered.store(true, .seq_cst);
        while (!e.open.load(.seq_cst)) std.Thread.yield() catch {};
        e.logger.warn("alert failed", .{});
    }
};

/// Opens the handler once `shutdown` has closed the subscribers' queues.
fn openOnShutdown(e: *LateEcho) void {
    while (!e.logger.engine.registry.subscribers[0].queue.isClosed()) std.Thread.yield() catch {};
    e.open.store(true, .seq_cst);
}

test "records a handler logs while shutdown waits for the subscribers still reach the output" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &out.writer } });
        var echo: LateEcho = .{ .logger = logger };
        _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = LateEcho.handler });
        logger.err("disk full", .{});
        while (!echo.entered.load(.seq_cst)) std.Thread.yield() catch {};
        const opener = try std.Thread.spawn(.{}, openOnShutdown, .{&echo});
        const stopped = logger.shutdown(.none);
        opener.join();
        const s = logger.stats();
        logger.deinit();
        try stopped;
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
        try testing.expectEqual(@as(u64, 0), s.dropped.closed);
    }
}

var other_vtable: std.Io.VTable = undefined;

/// `testing.io` under a vtable of its own: to the logger, an Io other than
/// `std.Io.Threaded`, as an evented one would be.
fn otherIo() std.Io {
    other_vtable = testing.io.vtable.*;
    return .{ .userdata = testing.io.userdata, .vtable = &other_vtable };
}

test "sync mode under an Io other than std.Io.Threaded: records a handler logs are dropped and counted" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, otherIo(), .{ .output = .{ .writer = &out.writer } });
    var echo: Echo = .{ .logger = logger };
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = Echo.handler });
    logger.err("disk full", .{});
    logger.unsubscribe(id);
    const s = logger.stats();
    logger.deinit();
    try testing.expectEqual(@as(u32, 1), echo.calls.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(u64, 1), s.hook_errors);
}

test "stats().alert_pending counts the records waiting in the subscribers' queues" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    for (0..3) |_| logger.err("alert", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try testing.expectEqual(@as(u64, 2), logger.stats().alert_pending);
    open.store(true, .seq_cst);
    logger.unsubscribe(id);
    try testing.expectEqual(@as(u64, 0), logger.stats().alert_pending);
}
