//! SSE streams through the server, on `http.testing`:
//! the route and its context, `subscribe` and its limits, the stream past
//! the request's deadline, `publish` and the queues, the heartbeat,
//! `close`, `on_close` and the stop.
const std = @import("std");
const v = @import("validator");
const Server = @import("../Server.zig");
const Context = @import("../Context.zig");
const sse = @import("../sse.zig");
const routes = @import("../routes.zig");
const mw = @import("../middleware.zig");
const TestingBackend = @import("../testing/Backend.zig");
const http_testing = @import("../testing.zig");

const testing = std.testing;
const Stream = TestingBackend.Stream;

// The middleware and the controller below are application code of the
// tests: zefir-http ships none.

/// Who the request is, as `identify` puts it.
const Who = struct { name: []const u8 };

fn identify(ctx: *Context) !mw.MiddlewareResult {
    try ctx.locals.put(Who, .{ .name = "ann" });
    return .next;
}

/// Counts the `onFinish` of the requests and keeps the last outcome.
const Finisher = struct {
    calls: std.atomic.Value(u32) = .init(0),
    /// Guards `last`: the streams of a test may end at once.
    mutex: std.Io.Mutex = .init,
    last: ?mw.Outcome = null,

    pub fn onFinish(self: *Finisher, ctx: *Context, outcome: mw.Outcome) !void {
        self.mutex.lockUncancelable(ctx.io());
        defer self.mutex.unlock(ctx.io());
        self.last = outcome;
        _ = self.calls.fetchAdd(1, .release);
    }
};

/// A text a context gave, copied.
const Text = struct {
    buf: [64]u8 = undefined,
    len: ?usize = null,

    fn set(t: *Text, text: ?[]const u8) void {
        const s = text orelse {
            t.len = null;
            return;
        };
        const n = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = n;
    }

    fn get(t: *const Text) ?[]const u8 {
        return t.buf[0 .. t.len orelse return null];
    }
};

/// What an `http.sse.Context` gave.
const Seen = struct {
    room: Text = .{},
    last_event_id: Text = .{},
    who: Text = .{},
    trace_id: Text = .{},
    handler: Text = .{},
    session: Text = .{},
    accept: Text = .{},
    cancelled: bool = false,
    deadline: bool = false,

    fn note(seen: *Seen, ctx: *sse.Context) void {
        seen.room.set(if (ctx.path(struct { room: []const u8 })) |p| p.room else |_| null);
        seen.last_event_id.set(ctx.lastEventId());
        seen.who.set(if (ctx.locals.get(Who)) |who| who.name else null);
        seen.trace_id.set(ctx.traceId());
        seen.handler.set(if (ctx.route()) |r| r.handler else null);
        seen.session.set(if (ctx.cookies(struct { session: ?[]const u8 = null })) |c| c.session else |_| null);
        seen.accept.set(if (ctx.headers(struct { accept: ?[]const u8 = null })) |h| h.accept else |_| null);
        const op = ctx.operation();
        seen.cancelled = op.isCancelled();
        seen.deadline = op.deadline != null;
    }
};

const KeyQuery = struct {
    key: []const u8 = "ann",
    /// "before": the handler fails before `subscribe`; "after": after it;
    /// "twice": it subscribes a second time; "close": it publishes an event
    /// and closes its key before it returns.
    then: []const u8 = "",
};

const EventsV1Controller = struct {
    live: *sse.Manager,
    /// Guards `seen`, `closed_seen`, `last_id` and `second`: handlers and
    /// `on_close` run on several threads.
    mutex: std.Io.Mutex = .init,
    /// Handlers that went past `subscribe`, and calls of `eventsClosed`.
    subscribed: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    seen: Seen = .{},
    closed_seen: Seen = .{},
    last_id: sse.SubscriptionId = .{ .index = 0, .generation = 0 },
    /// What a second `subscribe` gave.
    second: ?anyerror = null,

    pub const http_routes = routes.routes(.{
        .prefix = "/v1",
        .methods = .{
            .events = sse.get("/events/{room}", .{ .on_close = .eventsClosed }),
            .beating = sse.get("/beating", .{ .heartbeat = std.Io.Duration.fromMilliseconds(50), .on_close = .eventsClosed }),
            .plain = routes.get("/plain", .{}),
        },
    });

    pub fn events(self: *EventsV1Controller, ctx: *sse.Context) !void {
        const q = try ctx.query(KeyQuery);
        if (std.mem.eql(u8, q.then, "before")) return error.Unauthenticated;
        self.mutex.lockUncancelable(ctx.io());
        self.seen.note(ctx);
        self.mutex.unlock(ctx.io());
        const id = try self.live.subscribe(ctx, q.key);
        const second: ?anyerror = if (!std.mem.eql(u8, q.then, "twice")) null else if (self.live.subscribe(ctx, q.key)) |_| null else |err| err;
        self.mutex.lockUncancelable(ctx.io());
        self.last_id = id;
        self.second = second;
        self.mutex.unlock(ctx.io());
        _ = self.subscribed.fetchAdd(1, .release);
        if (std.mem.eql(u8, q.then, "after")) return error.Unavailable;
        if (std.mem.eql(u8, q.then, "close")) {
            try self.live.publish(ctx.operation(), ctx.io(), q.key, .{ .data = "early" });
            self.live.close(ctx.io(), q.key);
        }
    }

    pub fn beating(self: *EventsV1Controller, ctx: *sse.Context) !void {
        _ = try self.live.subscribe(ctx, "beat");
        _ = self.subscribed.fetchAdd(1, .release);
    }

    pub fn eventsClosed(self: *EventsV1Controller, ctx: *sse.Context) void {
        self.mutex.lockUncancelable(ctx.io());
        self.closed_seen.note(ctx);
        self.mutex.unlock(ctx.io());
        _ = self.closes.fetchAdd(1, .release);
    }

    pub fn plain(_: *EventsV1Controller, _: *Context) !void {}

    /// A copy of what the last handler and the last `on_close` saw.
    fn now(self: *EventsV1Controller) struct { seen: Seen, closed: Seen, id: sse.SubscriptionId, second: ?anyerror } {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return .{ .seen = self.seen, .closed = self.closed_seen, .id = self.last_id, .second = self.second };
    }
};

const Limits = struct {
    max_streams: u32 = 10_000,
    max_in_flight: u32 = 10_000,
    request_timeout: std.Io.Duration = .fromSeconds(30),
    shutdown_grace: std.Io.Duration = .fromSeconds(10),
};

/// A server of `EventsV1Controller` with a manager; it stays where `start`
/// put it.
const Fixture = struct {
    live: sse.Manager = undefined,
    events: EventsV1Controller = undefined,
    finisher: Finisher = .{},
    backend: TestingBackend = undefined,
    server: Server = undefined,

    /// `gpa` is the manager's.
    fn start(f: *Fixture, gpa: std.mem.Allocator, manager: sse.ManagerOptions, limits: Limits) !void {
        const io = testing.io;
        f.live = .init(gpa, manager);
        f.events = .{ .live = &f.live };
        f.backend = .init(testing.allocator);
        f.server = Server.init(testing.allocator, .{
            .backend = f.backend.backend(),
            .controllers = .{&f.events},
            .middleware = .{ identify, &f.finisher },
            .max_streams = limits.max_streams,
            .max_in_flight = limits.max_in_flight,
            .request_timeout = limits.request_timeout,
            .shutdown_grace = limits.shutdown_grace,
        }) catch |err| {
            f.live.deinit(io);
            return err;
        };
        f.server.start(io) catch |err| {
            f.server.deinit(io);
            f.live.deinit(io);
            return err;
        };
    }

    fn stop(f: *Fixture) void {
        f.server.deinit(testing.io);
        f.live.deinit(testing.io);
        f.backend.deinit();
    }

    fn open(f: *Fixture, target: []const u8) !*Stream {
        return f.backend.open(testing.io, .{ .method = .GET, .target = target });
    }

    fn publish(f: *Fixture, key: []const u8, event: anytype) !void {
        return f.live.publish(.root, testing.io, key, event);
    }
};

/// Ends the process with code 4 when a test runs past its limit, so that a
/// deadlock fails the run instead of hanging it.
const Watchdog = struct {
    future: std.Io.Future(void),

    fn start(name: []const u8) std.Io.ConcurrentError!Watchdog {
        return .{ .future = try testing.io.concurrent(watch, .{ testing.io, name }) };
    }

    fn stop(w: *Watchdog) void {
        w.future.cancel(testing.io);
    }

    fn watch(io: std.Io, name: []const u8) void {
        io.sleep(.fromSeconds(120), .awake) catch return;
        std.debug.print("test \"{s}\" still runs after 120 s: a deadlock\n", .{name});
        std.process.exit(4);
    }
};

/// Waits until `count` reaches `n`, five seconds at most.
fn waitCount(count: *const std.atomic.Value(u32), n: u32) !void {
    var tries: u32 = 0;
    while (count.load(.acquire) < n) : (tries += 1) {
        if (tries == 5000) return error.TestCountNotReached;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until the server has `n` streams open, five seconds at most.
fn waitStreams(server: *const Server, n: u32) !void {
    var tries: u32 = 0;
    while (http_testing.openStreams(server) != n) : (tries += 1) {
        if (tries == 5000) return error.TestStreamsStillOpen;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The next piece of `s`, five seconds at most; an error, not a panic,
/// when the response has ended instead.
fn nextPiece(s: *Stream) ![]const u8 {
    return (try s.next(testing.io, .fromSeconds(5))) orelse error.TestStreamEnded;
}

/// Reads the pieces of `s` until its response ends.
fn expectEnd(s: *Stream) !void {
    var pieces: u32 = 0;
    while (try s.next(testing.io, .fromSeconds(5))) |_| : (pieces += 1) {
        if (pieces == 10_000) return error.TestStreamDidNotEnd;
    }
}

fn sinceMs(start: std.Io.Timestamp) i64 {
    return start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
}

/// Sleeps `ms` milliseconds by the awake clock at least: a sleep of std's
/// threaded `Io` on Windows may end a tick of its timer early.
fn sleepAtLeast(ms: i64) std.Io.Cancelable!void {
    const io = testing.io;
    const start = std.Io.Clock.awake.now(io);
    while (true) {
        const left = ms - sinceMs(start);
        if (left <= 0) return;
        try io.sleep(.fromMilliseconds(left), .awake);
    }
}

fn expectProblemCode(res: *TestingBackend.Response, code: []const u8) !void {
    try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    const problem = try std.json.parseFromSliceLeaky(struct { code: []const u8 }, res.arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(code, problem.code);
}

test "an error before subscribe is a normal error response" {
    const io = testing.io;
    var dog = try Watchdog.start("an error before subscribe");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    var res = try f.backend.request(io, .{ .method = .GET, .target = "/v1/events/lobby?then=before" });
    defer res.deinit();
    try testing.expectEqual(401, res.status);
    try expectProblemCode(&res, "unauthenticated");
    try testing.expect(!res.aborted);
    // No stream opened, and none ended: no on_close; onFinish as for any
    // request.
    try waitCount(&f.finisher.calls, 1);
    try testing.expectEqual(0, f.events.closes.load(.acquire));
    try testing.expectEqual(0, http_testing.openStreams(&f.server));

    // HEAD would open a subscription: an SSE route does not serve it.
    var head = try f.backend.request(io, .{ .method = .HEAD, .target = "/v1/events/lobby" });
    defer head.deinit();
    try testing.expectEqual(405, head.status);
    try testing.expectEqualStrings("GET, OPTIONS", head.header("allow").?);
}

test "Last-Event-ID is ctx.lastEventId(); the context has the request's methods" {
    const io = testing.io;
    var dog = try Watchdog.start("Last-Event-ID is ctx.lastEventId()");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    const s = try f.backend.open(io, .{ .method = .GET, .target = "/v1/events/lobby?key=ann", .headers = &.{
        .{ "last-event-id", "41" },
        .{ "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ "cookie", "session=s1" },
        .{ "accept", "text/event-stream" },
    } });
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try waitCount(&f.events.subscribed, 1);
    const opening = f.events.now().seen;
    try testing.expectEqualStrings("41", opening.last_event_id.get().?);
    try testing.expectEqualStrings("lobby", opening.room.get().?);
    try testing.expectEqualStrings("ann", opening.who.get().?);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", opening.trace_id.get().?);
    try testing.expectEqualStrings("events", opening.handler.get().?);
    try testing.expectEqualStrings("s1", opening.session.get().?);
    try testing.expectEqualStrings("text/event-stream", opening.accept.get().?);
    // The handler runs as the request: its deadline and its token.
    try testing.expect(opening.deadline and !opening.cancelled);

    // on_close sees the same request, in the subscription's own context:
    // the same trace, no deadline, a token not canceled while it runs.
    f.live.close(io, "ann");
    try expectEnd(s);
    s.deinit(io);
    s_ended = true;
    try testing.expectEqual(1, f.events.closes.load(.acquire));
    const closing = f.events.now().closed;
    try testing.expectEqualStrings("41", closing.last_event_id.get().?);
    try testing.expectEqualStrings("lobby", closing.room.get().?);
    try testing.expectEqualStrings("ann", closing.who.get().?);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", closing.trace_id.get().?);
    try testing.expectEqualStrings("events", closing.handler.get().?);
    try testing.expect(!closing.deadline and !closing.cancelled);

    // Without the header: null.
    const fresh = try f.open("/v1/events/lobby?key=bob");
    defer fresh.deinit(io);
    try waitCount(&f.events.subscribed, 2);
    try testing.expectEqual(null, f.events.now().seen.last_event_id.get());
}

test "subscribe sends the stream headers and the handler returns at once" {
    const io = testing.io;
    var dog = try Watchdog.start("subscribe sends the stream headers");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the second subscribe is logged as a warning
    defer testing.log_level = level;

    const s = try f.open("/v1/events/lobby?key=ann&then=twice");
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try testing.expectEqual(200, s.status);
    try testing.expectEqualStrings("text/event-stream", s.header("content-type").?);
    try testing.expectEqualStrings("no-cache", s.header("cache-control").?);
    try testing.expectEqualStrings("no", s.header("x-accel-buffering").?);
    try testing.expectEqualStrings("chunked", s.header("transfer-encoding").?);
    // The handler went on past subscribe and returned; the stream lives on.
    try waitCount(&f.events.subscribed, 1);
    try testing.expectEqual(error.WriteFailed, f.events.now().second.?);
    try testing.expectError(error.Timeout, s.next(io, .fromMilliseconds(20)));
    try testing.expectEqual(0, http_testing.inFlight(&f.server));
    try testing.expectEqual(1, http_testing.openStreams(&f.server));

    try f.publish("ann", .{ .event = "todo.created", .id = "1", .data = .{ .id = 1, .title = "Buy milk" } });
    try testing.expectEqualStrings("event: todo.created\nid: 1\ndata: {\"id\":1,\"title\":\"Buy milk\"}\n\n", try nextPiece(s));
    // Another key's event is not this stream's.
    try f.publish("bob", .{ .data = "for bob" });
    try testing.expectError(error.Timeout, s.next(io, .fromMilliseconds(20)));

    // close(key) ends it with its last chunk; then on_close, once.
    f.live.close(io, "ann");
    try expectEnd(s);
    try testing.expect(!s.aborted());
    s.deinit(io);
    s_ended = true;
    try testing.expectEqual(1, f.events.closes.load(.acquire));
    try testing.expectEqual(0, http_testing.openStreams(&f.server));
}

test "a stream closed before it began still sends what was published to it" {
    const io = testing.io;
    var dog = try Watchdog.start("a stream closed before it began");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    // The handler publishes and closes its key before it returns, before
    // the stream runs: the event goes out, then the last chunk.
    const s = try f.open("/v1/events/lobby?key=ann&then=close");
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try testing.expectEqualStrings("data: \"early\"\n\n", try nextPiece(s));
    try expectEnd(s);
    try testing.expect(!s.aborted());
    s.deinit(io);
    s_ended = true;
    try testing.expectEqual(1, f.events.closes.load(.acquire));
}

test "max_subscriptions and max_streams give 503" {
    const io = testing.io;
    var dog = try Watchdog.start("max_subscriptions and max_streams give 503");
    defer dog.stop();
    for ([_]struct { sse.ManagerOptions, Limits }{
        .{ .{ .max_subscriptions = 1 }, .{} },
        .{ .{}, .{ .max_streams = 1 } },
    }) |limits| {
        var f: Fixture = .{};
        try f.start(testing.allocator, limits[0], limits[1]);
        defer f.stop();

        const first = try f.open("/v1/events/lobby?key=a");
        var first_ended = false;
        errdefer if (!first_ended) first.deinit(io);
        try testing.expectEqual(200, first.status);
        var over = try f.backend.request(io, .{ .method = .GET, .target = "/v1/events/lobby?key=b" });
        defer over.deinit();
        try testing.expectEqual(503, over.status);
        try expectProblemCode(&over, "unavailable");
        try testing.expectEqual(1, http_testing.openStreams(&f.server));

        // The first ends: its place comes back.
        first.deinit(io);
        first_ended = true;
        try testing.expectEqual(0, http_testing.openStreams(&f.server));
        const again = try f.open("/v1/events/lobby?key=c");
        defer again.deinit(io);
        try testing.expectEqual(200, again.status);
    }
}

test "an old SubscriptionId never matches a new subscription" {
    const io = testing.io;
    var dog = try Watchdog.start("an old SubscriptionId never matches a new subscription");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    const a = try f.open("/v1/events/lobby?key=a");
    try waitCount(&f.events.subscribed, 1);
    const first = f.events.now().id;
    const b = try f.open("/v1/events/lobby?key=b");
    defer b.deinit(io);
    try waitCount(&f.events.subscribed, 2);
    const second = f.events.now().id;
    try testing.expect(first.index != second.index);

    // The first ends; the next subscription takes its place, with a new
    // generation.
    a.deinit(io);
    const c = try f.open("/v1/events/lobby?key=c");
    defer c.deinit(io);
    try waitCount(&f.events.subscribed, 3);
    const third = f.events.now().id;
    try testing.expectEqual(first.index, third.index);
    try testing.expect(first.generation != third.generation);
}

test "an open stream does not hold an in-flight slot" {
    const io = testing.io;
    var dog = try Watchdog.start("an open stream does not hold an in-flight slot");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{ .max_in_flight = 1 });
    defer f.stop();

    const s = try f.open("/v1/events/lobby?key=ann");
    defer s.deinit(io);
    try waitCount(&f.events.subscribed, 1);
    try testing.expectEqual(0, http_testing.inFlight(&f.server));
    try testing.expectEqual(1, http_testing.openStreams(&f.server));
    for (0..3) |_| {
        var plain = try f.backend.request(io, .{ .method = .GET, .target = "/v1/plain" });
        defer plain.deinit();
        try testing.expectEqual(204, plain.status);
    }
}

test "the stream outlives the request deadline; HTTP middleware onFinish runs when it ends" {
    const io = testing.io;
    var dog = try Watchdog.start("the stream outlives the request deadline");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{ .request_timeout = .fromMilliseconds(50) });
    defer f.stop();

    const start = std.Io.Clock.awake.now(io);
    const s = try f.open("/v1/events/lobby?key=ann");
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try sleepAtLeast(150);
    try f.publish("ann", .{ .data = "still here" });
    try testing.expectEqualStrings("data: \"still here\"\n\n", try nextPiece(s));
    // onFinish waits for the end of the stream, not of its request.
    try testing.expectEqual(0, f.finisher.calls.load(.acquire));

    f.live.close(io, "ann");
    try expectEnd(s);
    s.deinit(io);
    s_ended = true;
    try testing.expectEqual(1, f.finisher.calls.load(.acquire));
    const outcome = f.finisher.last.?;
    try testing.expectEqual(200, outcome.status);
    try testing.expect(!outcome.aborted);
    try testing.expectEqual(null, outcome.err);
    try testing.expect(outcome.duration.toMilliseconds() >= 150 and sinceMs(start) >= 150);
}

/// A value whose transforms trim its title, with an outside name.
const TodoEvent = struct {
    title: []const u8,
    done_at: ?u64 = null,
    pub const field_rules = .{ .title = v.trim, .done_at = v.rename("doneAt") };
};

/// A value whose transform refuses the code "refused".
const Refusing = struct {
    code: []const u8,
    pub const field_rules = .{ .code = v.transformWith(refuse) };
};

fn refuse(_: std.mem.Allocator, code: []const u8) error{Refused}![]const u8 {
    if (std.mem.eql(u8, code, "refused")) return error.Refused;
    return code;
}

test "publish: data through transforms and outside names; a transform error returns to the publisher" {
    const io = testing.io;
    var dog = try Watchdog.start("publish: data through transforms and outside names");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    const s = try f.open("/v1/events/lobby?key=ann");
    defer s.deinit(io);
    try f.publish("ann", .{ .event = "todo.done", .data = TodoEvent{ .title = "  Buy milk ", .done_at = 5 } });
    try testing.expectEqualStrings("event: todo.done\ndata: {\"title\":\"Buy milk\",\"doneAt\":5}\n\n", try nextPiece(s));
    // The publisher gets the error of the transform, and nothing goes out.
    try testing.expectError(error.Refused, f.publish("ann", .{ .data = Refusing{ .code = "refused" } }));
    try f.publish("ann", .{ .data = Refusing{ .code = "kept" }, .retry = 3000 });
    try testing.expectEqualStrings("retry: 3000\ndata: {\"code\":\"kept\"}\n\n", try nextPiece(s));
}

test "publish: CR, LF or NUL in event or id is InvalidEvent" {
    const io = testing.io;
    var dog = try Watchdog.start("publish: CR, LF or NUL in event or id is InvalidEvent");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    const s = try f.open("/v1/events/lobby?key=ann");
    defer s.deinit(io);
    for ([_][]const u8{ "a\nb", "a\rb", "a\x00b", "\r\n" }) |bad| {
        try testing.expectError(error.InvalidEvent, f.publish("ann", .{ .event = bad, .data = 1 }));
        try testing.expectError(error.InvalidEvent, f.publish("ann", .{ .id = bad, .data = 1 }));
    }
    // Nothing went out; a valid one does.
    try testing.expectError(error.Timeout, s.next(io, .fromMilliseconds(20)));
    const id: ?[]const u8 = "7";
    try f.publish("ann", .{ .event = null, .id = id, .data = 1 });
    try testing.expectEqualStrings("id: 7\ndata: 1\n\n", try nextPiece(s));
}

test "publish: an event over .queue.max_bytes is EventTooLarge, and its subscribers stay" {
    const io = testing.io;
    var dog = try Watchdog.start("publish: an event over .queue.max_bytes is EventTooLarge");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{ .queue = .{ .max_bytes = 1024 } }, .{});
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the refusal is logged as a warning
    defer testing.log_level = level;

    const a = try f.open("/v1/events/lobby?key=k");
    defer a.deinit(io);
    const b = try f.open("/v1/events/lobby?key=k");
    defer b.deinit(io);
    try waitCount(&f.events.subscribed, 2);
    // No queue could hold it: refused, and sent to nobody.
    const big: [2048]u8 = @splat('x');
    try testing.expectError(error.EventTooLarge, f.publish("k", .{ .data = @as([]const u8, &big) }));
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(0, f.events.closes.load(.acquire));
    // Both streams are open and take the next event.
    try f.publish("k", .{ .data = "small" });
    for ([_]*Stream{ a, b }) |s| try testing.expectEqualStrings("data: \"small\"\n\n", try nextPiece(s));
}

/// An allocator that keeps the most bytes it held at once. Safe from any
/// number of threads when its child is.
const Peak = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    most: std.atomic.Value(usize) = .init(0),

    fn allocator(p: *Peak) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(ptr: *anyopaque) *Peak {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const p = of(ptr);
        const memory = p.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        p.moved(0, len);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const p = of(ptr);
        if (!p.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        p.moved(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const p = of(ptr);
        const moved_to = p.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        p.moved(memory.len, new_len);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const p = of(ptr);
        p.child.rawFree(memory, alignment, ret_addr);
        p.moved(memory.len, 0);
    }

    fn moved(p: *Peak, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            const now = p.live.fetchAdd(new_len - old_len, .acq_rel) + (new_len - old_len);
            _ = p.most.fetchMax(now, .acq_rel);
        } else {
            _ = p.live.fetchSub(old_len - new_len, .acq_rel);
        }
    }
};

test "a full queue closes the slow subscriber and memory stays bounded" {
    const io = testing.io;
    var dog = try Watchdog.start("a full queue closes the slow subscriber");
    defer dog.stop();
    var peak: Peak = .{ .child = testing.allocator };
    var f: Fixture = .{};
    try f.start(peak.allocator(), .{}, .{});
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the overflow is logged as a warning
    defer testing.log_level = level;

    // A client that reads nothing: the writer sticks in its first write,
    // and the queue fills behind it.
    const s = try f.backend.open(io, .{ .method = .GET, .target = "/v1/events/lobby?key=slow", .stalled = true });
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try testing.expectEqual(200, s.status);
    const big: [8 << 10]u8 = @splat('x');
    for (0..300) |_| try f.publish("slow", .{ .data = @as([]const u8, &big) });
    try waitCount(&f.events.closes, 1);
    // The stream is cut: its write never ended.
    try expectEnd(s);
    try testing.expect(s.aborted());
    s.deinit(io);
    s_ended = true;
    try testing.expectEqual(0, http_testing.openStreams(&f.server));
    // 300 events of 8 KiB came, 2.4 MiB: the subscriber held at most its
    // queue of 256 KiB and a batch of as much, the lists' spare room aside.
    try testing.expect(peak.most.load(.acquire) < 1 << 20);
}

test "heartbeat every interval" {
    const io = testing.io;
    var dog = try Watchdog.start("heartbeat every interval");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{});
    defer f.stop();

    const start = std.Io.Clock.awake.now(io);
    const s = try f.open("/v1/beating");
    defer s.deinit(io);
    // Every 50 ms without an event: a comment the client ignores.
    for (0..3) |_| try testing.expectEqualStrings(": ping\n\n", try nextPiece(s));
    const elapsed = sinceMs(start);
    try testing.expect(elapsed >= 150 and elapsed < 5000);
    // An event goes out between them.
    try f.publish("beat", .{ .event = "tick", .data = 1 });
    while (true) {
        const piece = try nextPiece(s);
        if (std.mem.eql(u8, piece, ": ping\n\n")) continue;
        try testing.expectEqualStrings("event: tick\ndata: 1\n\n", piece);
        break;
    }
    try testing.expectEqualStrings(": ping\n\n", try nextPiece(s));
}

/// Publishes to `key` until its subscriber, which reads nothing, falls
/// behind the queue of two events: five events do it, however its writer
/// took them.
fn overflow(f: *Fixture, key: []const u8) !void {
    for (0..5) |i| try f.publish(key, .{ .data = i });
}

test "on_close runs exactly once: client left, overflow, close(key), server stop" {
    const io = testing.io;
    var dog = try Watchdog.start("on_close runs exactly once");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{ .queue = .{ .max_events = 2 } }, .{});
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the overflow and the failure after subscribe are logged as warnings
    defer testing.log_level = level;

    // The client leaves: the stream is cut.
    const left = try f.open("/v1/events/lobby?key=left");
    left.leave(io);
    try expectEnd(left);
    try testing.expect(left.aborted());
    left.deinit(io);
    try testing.expectEqual(1, f.events.closes.load(.acquire));

    // The queue overflows: the stream is cut, its write stuck.
    const slow = try f.backend.open(io, .{ .method = .GET, .target = "/v1/events/lobby?key=slow", .stalled = true });
    try overflow(&f, "slow");
    try expectEnd(slow);
    try testing.expect(slow.aborted());
    slow.deinit(io);
    try testing.expectEqual(2, f.events.closes.load(.acquire));

    // close(key): what was published before goes out, then the last
    // chunk; what is published after does not.
    const closed = try f.open("/v1/events/lobby?key=closed");
    try f.publish("closed", .{ .data = "one" });
    try f.publish("closed", .{ .data = "two" });
    f.live.close(io, "closed");
    try f.publish("closed", .{ .data = "late" });
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    while (try closed.next(io, .fromSeconds(5))) |piece| try got.appendSlice(testing.allocator, piece);
    try testing.expectEqualStrings("data: \"one\"\n\ndata: \"two\"\n\n", got.items);
    try testing.expect(!closed.aborted());
    closed.deinit(io);
    try testing.expectEqual(3, f.events.closes.load(.acquire));

    // The handler fails after subscribe: the stream is cut at once.
    const failed = try f.open("/v1/events/lobby?key=failed&then=after");
    try expectEnd(failed);
    try testing.expect(failed.aborted());
    failed.deinit(io);
    try testing.expectEqual(4, f.events.closes.load(.acquire));

    // The server stops: its streams end at once, not after the grace, each
    // with its last chunk.
    const a = try f.open("/v1/events/lobby?key=a");
    const b = try f.open("/v1/events/lobby?key=b");
    const start = std.Io.Clock.awake.now(io);
    try f.server.shutdown(io);
    try testing.expect(sinceMs(start) < 5000);
    for ([_]*Stream{ a, b }) |s| {
        try expectEnd(s);
        try testing.expect(!s.aborted());
        s.deinit(io);
    }
    try testing.expectEqual(6, f.events.closes.load(.acquire));

    // Nothing runs twice.
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(6, f.events.closes.load(.acquire));
    try testing.expectEqual(6, f.finisher.calls.load(.acquire));
    try testing.expectEqual(0, http_testing.openStreams(&f.server));
}

test "the stop cuts a stream whose last events a client that reads nothing holds past the grace" {
    const io = testing.io;
    var dog = try Watchdog.start("the stop cuts a stream held past the grace");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{}, .{ .shutdown_grace = .fromMilliseconds(200) });
    defer f.stop();

    // The writer sticks in the write of the event: the stream closes softly,
    // sending what was published, which the client never takes.
    const s = try f.backend.open(io, .{ .method = .GET, .target = "/v1/events/lobby?key=stuck", .stalled = true });
    var s_ended = false;
    errdefer if (!s_ended) s.deinit(io);
    try waitCount(&f.events.subscribed, 1);
    try f.publish("stuck", .{ .data = "stuck" });
    try io.sleep(.fromMilliseconds(20), .awake);
    const start = std.Io.Clock.awake.now(io);
    try f.server.shutdown(io);
    // Within the grace and the second after it, the stream cut.
    const elapsed = sinceMs(start);
    try testing.expect(elapsed >= 150 and elapsed < 5000);
    try expectEnd(s);
    try testing.expect(s.aborted());
    s.deinit(io);
    s_ended = true;
    // Its end ran whole: .on_close and onFinish once, and its places back.
    try testing.expectEqual(1, f.events.closes.load(.acquire));
    try testing.expectEqual(1, f.finisher.calls.load(.acquire));
    try testing.expect(f.finisher.last.?.aborted);
    try testing.expectEqual(0, http_testing.openStreams(&f.server));
    try testing.expectEqual(0, http_testing.inFlight(&f.server));
}

/// The streams of rooms, whose `.on_close` tells the others of the room,
/// through the same manager, that someone left.
const RoomsV1Controller = struct {
    live: *sse.Manager,
    subscribed: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    /// Publishes of `.on_close` that failed.
    farewells_failed: std.atomic.Value(u32) = .init(0),

    pub const http_routes = routes.routes(.{
        .prefix = "/v1",
        .methods = .{ .events = sse.get("/rooms/{room}/events", .{ .on_close = .left }) },
    });

    pub fn events(self: *RoomsV1Controller, ctx: *sse.Context) !void {
        const p = try ctx.path(struct { room: []const u8 });
        _ = try self.live.subscribe(ctx, p.room);
        _ = self.subscribed.fetchAdd(1, .release);
    }

    pub fn left(self: *RoomsV1Controller, ctx: *sse.Context) void {
        const room = if (ctx.path(struct { room: []const u8 })) |p| p.room else |_| "?";
        self.live.publish(ctx.operation(), ctx.io(), room, .{ .event = "left", .data = ctx.requestId() }) catch {
            _ = self.farewells_failed.fetchAdd(1, .release);
        };
        _ = self.closes.fetchAdd(1, .release);
    }
};

/// An `onFinish` that takes its time: the end of each stream goes on after
/// its manager's `deinit` has returned.
const SlowFinish = struct {
    done: std.atomic.Value(u32) = .init(0),

    pub fn onFinish(self: *SlowFinish, ctx: *Context, _: mw.Outcome) !void {
        try ctx.io().sleep(.fromMilliseconds(50), .awake);
        _ = self.done.fetchAdd(1, .release);
    }
};

test "Manager.deinit while the server runs waits for its streams, which never touch it after" {
    const io = testing.io;
    var dog = try Watchdog.start("Manager.deinit while the server runs");
    defer dog.stop();
    var live: sse.Manager = .init(testing.allocator, .{});
    var rooms: RoomsV1Controller = .{ .live = &live };
    var slow: SlowFinish = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&rooms}, .middleware = .{&slow} });
    defer server.deinit(io);
    try server.start(io);

    const a = try backend.open(io, .{ .method = .GET, .target = "/v1/rooms/lobby/events" });
    defer a.deinit(io);
    const b = try backend.open(io, .{ .method = .GET, .target = "/v1/rooms/lobby/events" });
    defer b.deinit(io);
    try waitCount(&rooms.subscribed, 2);
    // Each stream sent an event: its queue holds memory of the manager's
    // allocator.
    try live.publish(.root, io, "lobby", .{ .data = "hello" });
    for ([_]*Stream{ a, b }) |s| try testing.expectEqualStrings("data: \"hello\"\n\n", try nextPiece(s));

    // The manager goes while the server runs: it closes both streams and
    // returns once their .on_close has run, each publishing through it.
    live.deinit(io);
    try testing.expectEqual(2, rooms.closes.load(.acquire));
    try testing.expectEqual(0, rooms.farewells_failed.load(.acquire));
    // Both ended whole; the farewells came after their ends were decided.
    for ([_]*Stream{ a, b }) |s| {
        try expectEnd(s);
        try testing.expect(!s.aborted());
    }
    // The ends go on without the manager: onFinish, then the places.
    try waitCount(&slow.done, 2);
    try waitStreams(&server, 0);
}

test "stream slots come back after every way a stream ends" {
    // Review focus 2: 100 streams ended by each way (the client left,
    // close(key), an overflow, a failure after subscribe), four at a time
    // on four places; then four new streams all open, and the stop ends
    // them.
    const io = testing.io;
    var dog = try Watchdog.start("stream slots come back after every way a stream ends");
    defer dog.stop();
    var f: Fixture = .{};
    try f.start(testing.allocator, .{ .queue = .{ .max_events = 2 } }, .{ .max_streams = 4 });
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the overflows and the failures after subscribe are logged as warnings
    defer testing.log_level = level;

    var closes: u32 = 0;
    for (0..100) |_| {
        const left = try f.open("/v1/events/lobby?key=left");
        const closed = try f.open("/v1/events/lobby?key=closed");
        const slow = try f.backend.open(io, .{ .method = .GET, .target = "/v1/events/lobby?key=slow", .stalled = true });
        const failed = try f.open("/v1/events/lobby?key=failed&then=after");
        for ([_]*Stream{ left, closed, slow, failed }) |s| try testing.expectEqual(200, s.status);
        left.leave(io);
        f.live.close(io, "closed");
        try overflow(&f, "slow");
        for ([_]*Stream{ left, closed, slow, failed }) |s| {
            try expectEnd(s);
            s.deinit(io);
        }
        closes += 4;
        try testing.expectEqual(closes, f.events.closes.load(.acquire));
        try testing.expectEqual(0, http_testing.openStreams(&f.server));
    }

    // Every place is free: four new streams all open, a fifth gets 503.
    var held: [4]*Stream = undefined;
    for (&held) |*s| {
        s.* = try f.open("/v1/events/lobby?key=held");
        try testing.expectEqual(200, s.*.status);
    }
    var over = try f.backend.request(io, .{ .method = .GET, .target = "/v1/events/lobby?key=over" });
    defer over.deinit();
    try testing.expectEqual(503, over.status);

    // The stop ends them, and their places come back.
    try f.server.shutdown(io);
    for (held) |s| {
        try expectEnd(s);
        try testing.expect(!s.aborted());
        s.deinit(io);
    }
    try testing.expectEqual(closes + 4, f.events.closes.load(.acquire));
    try testing.expectEqual(0, http_testing.openStreams(&f.server));
}
