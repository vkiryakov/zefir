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

test "subscribe frees what it took when an allocation fails" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(failing.allocator(), testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    var failures: usize = 0;
    var n: usize = 0;
    while (true) : (n += 1) {
        // Relative to the allocations so far: allocation n (from 0) of this
        // call fails.
        failing.fail_index = failing.alloc_index + n;
        const id = logger.subscribe(.{ .levels = &.{.err}, .handler = ignore }) catch |e| {
            try testing.expectEqual(@as(log.SubscribeError, error.OutOfMemory), e);
            failures += 1;
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        logger.unsubscribe(id);
        break;
    }
    try testing.expectEqual(@as(usize, 2), failures); // the queue, then the buffer a record is copied out into
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
    defer open.store(true, .seq_cst);
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
        var live = true;
        defer if (live) logger.deinit();
        var echo: Echo = .{ .logger = logger };
        const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = Echo.handler });
        logger.err("disk full", .{});
        logger.unsubscribe(id);
        logger.deinit();
        live = false;
        try testing.expectEqual(@as(u32, 1), echo.calls.load(.seq_cst));
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
        try testing.expect(std.mem.find(u8, out.written(), "\"message\":\"alert failed\"") != null);
    }
}

/// Hands its post to an Io task on its first call; the task logs that the
/// post failed.
const HandOff = struct {
    logger: log.Logger,
    calls: std.atomic.Value(u32) = .init(0),
    logged: std.atomic.Value(bool) = .init(false),

    fn post(h: *HandOff) void {
        h.logger.err("webhook post failed", .{});
        h.logged.store(true, .seq_cst);
    }

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const h: *HandOff = @ptrCast(@alignCast(context orelse return error.NoContext));
        if (h.calls.fetchAdd(1, .seq_cst) > 0) return;
        var task = try testing.io.concurrent(post, .{h});
        task.await(testing.io);
    }
};

test "a record an Io task of a handler logs reaches the subscribers: only the handler's own thread is kept out" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &out.writer } });
        defer logger.deinit();
        var hand_off: HandOff = .{ .logger = logger };
        const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &hand_off, .handler = HandOff.handler });
        logger.err("disk full", .{});
        var waited: usize = 0;
        while (!hand_off.logged.load(.seq_cst) and waited < 5000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
        logger.unsubscribe(id); // the task's record is queued for the handler: it gets it first
        try logger.flush(.none);
        try testing.expect(hand_off.logged.load(.seq_cst));
        try testing.expectEqual(@as(u32, 2), hand_off.calls.load(.seq_cst));
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
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

test "deinit without a shutdown waits until the subscribers have handled their queues" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
        var sink: std.Io.Writer.Discarding = .init(&.{});
        var open: std.atomic.Value(bool) = .init(false);
        var c: Collector = .init();
        defer c.deinit();
        c.gate = &open;
        {
            const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &sink.writer } });
            errdefer logger.deinit();
            errdefer open.store(true, .seq_cst);
            _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
            for (0..3) |_| logger.err("queued", .{});
            while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
            // Two records are still queued for the handler when deinit begins.
            const opener = try std.Thread.spawn(.{}, openOnStopping, .{ &open, logger });
            logger.deinit();
            opener.join();
        }
        try testing.expectEqual(@as(usize, 3), c.events.items.len);
    }
}

/// Opens `open` once `deinit` has begun its shutdown; `deinit` waits for
/// the handler that `open` holds, so the logger is alive while this reads
/// it.
fn openOnStopping(open: *std.atomic.Value(bool), logger: log.Logger) void {
    while (logger.engine.state.load(.seq_cst) == .running) std.Thread.yield() catch {};
    open.store(true, .seq_cst);
}

test "a shutdown that times out on a subscriber leaves it to deinit, which stops it after the record in hand" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    var live = true;
    defer if (live) {
        open.store(true, .seq_cst);
        logger.deinit();
    };
    _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    for (0..3) |_| logger.err("queued", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    const timed_out = logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } });
    const opener = try std.Thread.spawn(.{}, openOnAbandon, .{ &open, logger });
    logger.deinit();
    live = false;
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

/// Logs a warning from its handler once `go` is set: in `.block` mode with
/// the queue full, that call waits for room. Then it waits for `release`,
/// so the logger stays alive while the test looks at it.
const BlockedEcho = struct {
    logger: log.Logger,
    go: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const e: *BlockedEcho = @ptrCast(@alignCast(context orelse return error.NoContext));
        while (!e.go.load(.seq_cst)) std.Thread.yield() catch {};
        e.logger.warn("alert failed", .{});
        e.returned.store(true, .seq_cst);
        while (!e.release.load(.seq_cst)) std.Thread.yield() catch {};
    }
};

fn deinitLogger(logger: log.Logger) void {
    logger.deinit();
}

test "deinit after a shutdown that timed out ends a handler's wait for room in .block mode" {
    var held: Held = .{};
    var blocked = false;
    var timed_out: error{Timeout}!void = {};
    var returned = false;
    var refused: u64 = 0;
    {
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{
            .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1, .overflow = .block } },
            .output = .{ .writer = &held.writer },
        });
        var echo: BlockedEcho = .{ .logger = logger };
        const q = &logger.engine.queue.?;
        // Until a thread runs deinit, an error lets every waiter go and
        // frees the logger here.
        errdefer {
            held.open.store(true, .seq_cst);
            echo.go.store(true, .seq_cst);
            _ = q.close();
            echo.release.store(true, .seq_cst);
            logger.deinit();
        }
        _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = BlockedEcho.handler });
        logger.info("held", .{}); // the writer thread takes it and waits inside the write
        held.waitEntered();
        logger.err("alert", .{}); // to the handler, and into the queue
        logger.info("fill", .{}); // the queue is full now
        echo.go.store(true, .seq_cst); // the handler's warning waits for room
        var waited: usize = 0;
        while (q.space_waiters.load(.seq_cst) == 0 and waited < 5000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        blocked = q.space_waiters.load(.seq_cst) == 1;
        timed_out = logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } });
        const stopper = try std.Thread.spawn(.{}, deinitLogger, .{logger});
        // deinit cannot free the logger before the handler returns, and the
        // handler waits for `release`: the logger is alive while this reads
        // it. The writer thread stays inside its write, so only the closed
        // queue can end the handler's wait.
        waited = 0;
        while (!echo.returned.load(.seq_cst) and waited < 2000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        returned = echo.returned.load(.seq_cst);
        if (!returned) _ = q.close(); // deinit left it waiting: let it go, so the test fails instead of hanging
        held.open.store(true, .seq_cst);
        refused = logger.stats().dropped.closed;
        echo.release.store(true, .seq_cst);
        stopper.join();
    }
    try testing.expect(blocked);
    try testing.expectError(error.Timeout, timed_out);
    try testing.expect(returned);
    try testing.expectEqual(@as(u64, 1), refused); // the handler's warning, refused by the closed queue
}

/// A gate that opens after a delay and keeps the time it opened.
const TimedGate = struct {
    open: std.atomic.Value(bool) = .init(false),
    /// Awake-clock nanoseconds when `open` was set.
    opened_at: std.atomic.Value(i64) = .init(0),

    fn openAfter(gate: *TimedGate, ms: i64) void {
        testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
        gate.opened_at.store(@intCast(std.Io.Clock.awake.now(testing.io).nanoseconds), .seq_cst);
        gate.open.store(true, .seq_cst);
    }
};

test "shutdown has one deadline for the subscribers and the queue" {
    var held: Held = .{};
    var gate: TimedGate = .{};
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &gate.open;
    const timeout_ms = 300;
    var stopped: error{Timeout}!void = {};
    var after_open: i96 = 0;
    {
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &held.writer } });
        defer logger.deinit();
        defer held.open.store(true, .seq_cst);
        defer gate.open.store(true, .seq_cst);
        _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
        logger.info("held", .{}); // the writer thread waits inside this write until the end
        held.waitEntered();
        logger.err("alert", .{});
        while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
        // The handler returns 200 ms into the shutdown; the queue stays stuck.
        const opener = try std.Thread.spawn(.{}, TimedGate.openAfter, .{ &gate, 200 });
        stopped = logger.shutdown(.{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } });
        const end = std.Io.Clock.awake.now(testing.io).nanoseconds;
        opener.join();
        after_open = end - gate.opened_at.load(.seq_cst);
    }
    try testing.expectError(error.Timeout, stopped);
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
    // A queue wait with a timeout of its own would end a whole timeout
    // after the handler returned.
    try testing.expect(after_open < timeout_ms * std.time.ns_per_ms);
}

test "an error record reaches the subscribers even when the queue refuses it" {
    var held: Held = .{};
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 2, .batch_size = 1 } },
        .output = .{ .writer = &held.writer },
    });
    defer logger.deinit();
    defer held.open.store(true, .seq_cst);
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
    defer open.store(true, .seq_cst);
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    logger.err("held", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    var after_handler: std.atomic.Value(u32) = .init(0);
    {
        var threads: [2]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |thread| thread.join();
        defer open.store(true, .seq_cst);
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, unsubscribeThenCheck, .{ logger, id, &c, &after_handler });
            spawned += 1;
        }
        try testing.io.sleep(.fromMilliseconds(20), .awake); // both are inside unsubscribe by now
    }
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
    defer open.store(true, .seq_cst);
    const busy_id = try logger.subscribe(.{ .levels = &.{.err}, .context = &busy, .handler = Collector.handler });
    const idle_id = try logger.subscribe(.{ .levels = &.{.warn}, .handler = ignore });
    logger.err("held", .{});
    while (busy.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    var busy_gone: std.atomic.Value(bool) = .init(false);
    var idle_gone: std.atomic.Value(bool) = .init(false);
    const remover = try std.Thread.spawn(.{}, unsubscribeAndMark, .{ logger, busy_id, &busy_gone });
    defer remover.join();
    var idle_remover: ?std.Thread = null;
    defer if (idle_remover) |thread| thread.join();
    defer open.store(true, .seq_cst);
    try testing.io.sleep(.fromMilliseconds(20), .awake); // the remover waits for the held handler
    idle_remover = try std.Thread.spawn(.{}, unsubscribeAndMark, .{ logger, idle_id, &idle_gone });
    var waited: usize = 0;
    while (!idle_gone.load(.seq_cst) and waited < 2000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expect(idle_gone.load(.seq_cst) and !busy_gone.load(.seq_cst));
}

test "after a shutdown that timed out, unsubscribe waits only for the call in hand" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    defer open.store(true, .seq_cst);
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
        var live = true;
        defer if (live) {
            echo.open.store(true, .seq_cst);
            logger.deinit();
        };
        _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = LateEcho.handler });
        logger.err("disk full", .{});
        while (!echo.entered.load(.seq_cst)) std.Thread.yield() catch {};
        const opener = try std.Thread.spawn(.{}, openOnShutdown, .{&echo});
        const stopped = logger.shutdown(.none);
        opener.join();
        const s = logger.stats();
        logger.deinit();
        live = false;
        try stopped;
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
        try testing.expectEqual(@as(u64, 0), s.dropped.closed);
    }
}

/// Logs a warning through the std.log bridge once the logger has begun to
/// stop.
const BridgeEcho = struct {
    logger: log.Logger,

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const e: *BridgeEcho = @ptrCast(@alignCast(context orelse return error.NoContext));
        while (e.logger.engine.state.load(.seq_cst) == .running) std.Thread.yield() catch {};
        log.stdLogFn(.warn, .webhook, "alert post failed", .{});
    }
};

test "what a handler logs through std.log while deinit waits for the subscribers reaches the output" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} } }) |mode| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        {
            const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &out.writer } });
            defer logger.deinit(); // no shutdown first: deinit runs one
            var echo: BridgeEcho = .{ .logger = logger };
            _ = try logger.subscribe(.{ .levels = &.{.err}, .context = &echo, .handler = BridgeEcho.handler });
            logger.installStdLog();
            logger.err("disk full", .{});
        }
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "alert post failed"));
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

var app_clock_reads: std.atomic.Value(u32) = .init(0);
var counting_vtable: std.Io.VTable = undefined;

fn countingNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    _ = app_clock_reads.fetchAdd(1, .seq_cst);
    return testing.io.vtable.now(userdata, clock);
}

/// `testing.io`, counting the reads of its clock. To the logger it is an Io
/// other than `std.Io.Threaded`, as an evented one would be.
fn countingIo() std.Io {
    counting_vtable = testing.io.vtable.*;
    counting_vtable.now = countingNow;
    return .{ .userdata = testing.io.userdata, .vtable = &counting_vtable };
}

/// Logs a warning from inside the handler.
const Warner = struct {
    logger: log.Logger,
    calls: std.atomic.Value(u32) = .init(0),

    fn handler(context: ?*anyopaque, _: *const log.Event) anyerror!void {
        const w: *Warner = @ptrCast(@alignCast(context orelse return error.NoContext));
        _ = w.calls.fetchAdd(1, .seq_cst);
        w.logger.warn("alert sent", .{});
    }
};

test "a record a handler logs reads the logger's own clock, never the application's" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Queued: in sync mode, under this Io, the handler's record is dropped.
    const logger: log.Logger = try .init(testing.allocator, countingIo(), .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    var warner: Warner = .{ .logger = logger };
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &warner, .handler = Warner.handler });
    const before = app_clock_reads.load(.seq_cst);
    logger.err("disk full", .{});
    logger.unsubscribe(id); // waits for the handler's record
    const reads = app_clock_reads.load(.seq_cst) - before;
    try logger.flush(.none);
    try testing.expectEqual(@as(u32, 1), warner.calls.load(.seq_cst));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(u32, 1), reads); // the caller's record only
}

test "stats().alert_pending counts the records waiting in the subscribers' queues" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var open: std.atomic.Value(bool) = .init(false);
    var c: Collector = .init();
    defer c.deinit();
    c.gate = &open;
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &sink.writer } });
    defer logger.deinit();
    defer open.store(true, .seq_cst);
    const id = try logger.subscribe(.{ .levels = &.{.err}, .context = &c, .handler = Collector.handler });
    for (0..3) |_| logger.err("alert", .{});
    while (c.entered.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try testing.expectEqual(@as(u64, 2), logger.stats().alert_pending);
    open.store(true, .seq_cst);
    logger.unsubscribe(id);
    try testing.expectEqual(@as(u64, 0), logger.stats().alert_pending);
}

/// Counts a subscription's handler calls, and those after it was removed.
const Watch = struct {
    calls: std.atomic.Value(u32) = .init(0),
    removed: std.atomic.Value(bool) = .init(false),
    late: std.atomic.Value(u32) = .init(0),
    broken: std.atomic.Value(u32) = .init(0),

    fn handler(context: ?*anyopaque, event: *const log.Event) anyerror!void {
        const w: *Watch = @ptrCast(@alignCast(context orelse return error.NoContext));
        if (w.removed.load(.seq_cst)) _ = w.late.fetchAdd(1, .seq_cst);
        const whole = std.mem.eql(u8, event.message, "load") and std.mem.endsWith(u8, event.line, "}") and
            std.mem.find(u8, event.line, "\"message\":\"load\"") != null;
        if (!whole) _ = w.broken.fetchAdd(1, .seq_cst);
        _ = w.calls.fetchAdd(1, .seq_cst);
    }
};

fn logUntil(logger: log.Logger, stop: *const std.atomic.Value(bool)) void {
    var i: u64 = 0;
    while (!stop.load(.seq_cst)) : (i += 1) logger.err("load", .{ .i = i });
}

/// Adds and removes a subscriber for each of `watches` while 4 threads
/// log, and stops the threads before it returns.
fn churn(logger: log.Logger, watches: []Watch) !void {
    var stop: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        stop.store(true, .seq_cst);
        for (threads[0..spawned]) |t| t.join();
    }
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, logUntil, .{ logger, &stop });
        spawned += 1;
    }
    for (watches) |*w| {
        const id = try logger.subscribe(.{ .levels = &.{.err}, .capacity = 16, .context = w, .handler = Watch.handler });
        try testing.io.sleep(.fromMilliseconds(2), .awake);
        logger.unsubscribe(id);
        w.removed.store(true, .seq_cst);
    }
}

test "subscribers come and go while 4 threads log: no call after unsubscribe, no broken event, counters add up" {
    for ([_]log.Mode{ .sync, .{ .queued = .{} }, .{ .queued = .{ .overflow = .block } } }) |mode| {
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = mode, .output = .{ .writer = &sink.writer } });
        defer logger.deinit();
        var watches: [8]Watch = @splat(.{});
        try churn(logger, &watches);
        try logger.flush(.none);
        var calls: u32 = 0;
        for (&watches) |*w| {
            try testing.expectEqual(@as(u32, 0), w.late.load(.seq_cst));
            try testing.expectEqual(@as(u32, 0), w.broken.load(.seq_cst));
            calls += w.calls.load(.seq_cst);
        }
        try testing.expect(calls > 0);
        const s = logger.stats();
        try testing.expectEqual(s.accepted, s.written + s.dropped.queue_full + s.dropped.err + s.pending);
        try testing.expectEqual(@as(u64, 0), logger.engine.registry.levels.load(.seq_cst));
    }
}

test "an event matches its line: text, a quoted scope, the call site, a cut record and a std.log record" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Collector = .init();
    defer c.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .format = .text, .max_record_bytes = 400, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    const id = try logger.subscribe(.{ .levels = &.{ .info, .warn }, .context = &c, .handler = Collector.handler });
    logger.scoped("db pool").withContext(try traced()).info("Query done", .{ .src = @src(), .ms = 5 });
    logger.warn(&@as([600]u8, @splat('x')), .{});
    logger.installStdLog();
    log.stdLogFn(.info, .std_scope, "n={d}", .{7});
    log.uninstallStdLog();
    logger.unsubscribe(id);
    try testing.expectEqual(@as(usize, 3), c.events.items.len);
    for (0..3) |i| try testing.expectEqualStrings(try lineAt(out.written(), i), (try c.get(i)).line);
    const first = try c.get(0);
    try testing.expectEqualStrings("db pool", first.scope);
    try testing.expectEqualStrings("Query done", first.message);
    try testing.expectEqualStrings("00f067aa0ba902b7", first.span_id orelse return error.TestNoSpanId);
    try testing.expectStringEndsWith((try c.get(1)).message, "…");
    const third = try c.get(2);
    try testing.expectEqualStrings("std_scope", third.scope);
    try testing.expectEqualStrings("n=7", third.message);
}

/// An interceptor that keeps a copy of the line and trace id it saw.
const Peek = struct {
    line: [512]u8 = undefined,
    line_len: usize = 0,
    trace_id: [32]u8 = undefined,
    traced: bool = false,

    fn filter(context: ?*anyopaque, event: *const log.Event) bool {
        const p: *Peek = @ptrCast(@alignCast(context orelse return true));
        p.line_len = @min(event.line.len, p.line.len);
        @memcpy(p.line[0..p.line_len], event.line[0..p.line_len]);
        if (event.trace_id) |id| {
            if (id.len == p.trace_id.len) {
                @memcpy(&p.trace_id, id);
                p.traced = true;
            }
        }
        return true;
    }
};

test "an interceptor's event has the line written and the trace ids" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var peek: Peek = .{};
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    try logger.use(.{ .context = &peek, .filter = Peek.filter });
    logger.withContext(try traced()).info("Checked", .{ .ok = true });
    try testing.expectEqualStrings(try lineAt(out.written(), 0), peek.line[0..peek.line_len]);
    try testing.expect(peek.traced);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &peek.trace_id);
}

/// Tries to subscribe `results.len` times; each result is null or the
/// error.
fn subscribeMany(logger: log.Logger, results: []?anyerror) void {
    for (results) |*r| {
        r.* = if (logger.subscribe(.{ .levels = &.{.err}, .capacity = 2, .handler = ignore })) |_| null else |e| e;
    }
}

test "subscribe racing shutdown: each call subscribes, or is refused with ShutDown; nothing hangs or leaks" {
    for (0..10) |round| {
        var sink: std.Io.Writer.Discarding = .init(&.{});
        const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .mode = .{ .queued = .{} }, .output = .{ .writer = &sink.writer } });
        var live = true;
        defer if (live) logger.deinit();
        var results: [8]?anyerror = @splat(error.TestNotRun);
        const subscriber = try std.Thread.spawn(.{}, subscribeMany, .{ logger, &results });
        for (0..round) |_| std.Thread.yield() catch {};
        const stopped = logger.shutdown(.none);
        subscriber.join();
        logger.deinit();
        live = false;
        try stopped;
        for (results) |r| {
            if (r) |e| try testing.expectEqual(@as(anyerror, error.ShutDown), e);
        }
    }
}
