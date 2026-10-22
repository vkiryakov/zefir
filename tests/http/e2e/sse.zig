//! SSE on `http.native` over loopback TCP, on zio: the head of a stream at
//! once, events in the order they were published, a heartbeat while none
//! comes, the end of the stream when the client leaves, and its last chunk
//! when the server closes it, after which the connection serves the next
//! request; a stream to an HTTP/1.0 client, which ends with the
//! connection; and a client that reads nothing, which holds `close(key)`
//! only until the write timeout. Each scenario runs on one executor, then
//! on four.

const std = @import("std");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");
const e2e = @import("native.zig");

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;
const get = e2e.get;

const Todo = struct { id: u64, title: []const u8 };

/// The application of the scenarios: one stream of every client.
const App = struct {
    live: *http.sse.Manager,
    subscribed: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),

    pub const http_routes = http.routes(.{ .methods = .{
        .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromMilliseconds(200), .on_close = .eventsClosed }),
        .hello = http.get("/hello", .{}),
    } });

    pub fn hello(_: *App, ctx: *http.Context) !void {
        try ctx.response.text("hello");
    }

    pub fn events(self: *App, ctx: *http.sse.Context) !void {
        _ = try self.live.subscribe(ctx, "all");
        _ = self.subscribed.fetchAdd(1, .release);
    }

    pub fn eventsClosed(self: *App, _: *http.sse.Context) void {
        _ = self.closes.fetchAdd(1, .release);
    }
};

/// A server of `App` on `http.native`, on a free port of loopback. It
/// stays where `start` put it.
const Fixture = struct {
    live: http.sse.Manager,
    app: App,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io) !void {
        return f.startWith(io, .{}, .{});
    }

    fn startWith(f: *Fixture, io: Io, options: http.sse.ManagerOptions, timeouts: http.native.Timeouts) !void {
        f.live = .init(gpa, options);
        errdefer f.live.deinit(io);
        f.app = .{ .live = &f.live };
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0, .timeouts = timeouts });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{ .controllers = .{&f.app} }, .{ .listen = .{ .backend = f.native.backend() } });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.live.deinit(io);
        f.native.deinit();
    }

    fn connect(f: *Fixture, io: Io) !raw.Client {
        return raw.Client.connect(io, gpa, f.native.port());
    }

    fn publish(f: *Fixture, io: Io, event: anytype) !void {
        return f.live.publish(.root, io, "all", event);
    }
};

/// Waits until the server has no stream open, a second at most.
fn waitNoStreams(io: Io, server: *const http.Server) !void {
    const start = Io.Clock.awake.now(io);
    while (http.testing.openStreams(server) != 0) {
        if (e2e.sinceMs(io, start) > 1000) return error.TestStreamsStillOpen;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "SSE over the network: events arrive as published; the stream ends when the client leaves" {
    try runtime.forEachRuntime(gpa, eventsOverNetwork);
}

fn eventsOverNetwork(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "SSE over the network");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/events"));
    // The head comes at once, before any event.
    try testing.expect(try c.readUntil(io, "\r\n\r\n", .fromSeconds(5)));
    const head = c.kept();
    try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    for ([_][]const u8{ "content-type: text/event-stream\r\n", "cache-control: no-cache\r\n", "x-accel-buffering: no\r\n", "transfer-encoding: chunked\r\n" }) |field| {
        if (std.ascii.findIgnoreCase(head, field) == null) {
            std.debug.print("no \"{s}\" in the head:\n{s}\n", .{ field[0 .. field.len - 2], head });
            return error.TestFieldMissing;
        }
    }
    try e2e.waitCount(io, &f.app.subscribed, 1, 5000);

    // Two events, in the order they were published; then, while none
    // comes, the heartbeat.
    try f.publish(io, .{ .event = "todo.created", .id = "1", .data = Todo{ .id = 1, .title = "Buy milk" } });
    try f.publish(io, .{ .event = "todo.done", .id = "2", .data = Todo{ .id = 1, .title = "Buy milk" } });
    const done_event = "event: todo.done\nid: 2\ndata: {\"id\":1,\"title\":\"Buy milk\"}\n\n";
    try testing.expect(try c.readUntil(io, done_event, .fromSeconds(5)));
    const created = std.mem.find(u8, c.kept(), "event: todo.created\nid: 1\ndata: {\"id\":1,\"title\":\"Buy milk\"}\n\n") orelse return error.TestEventMissing;
    try testing.expect(created < std.mem.find(u8, c.kept(), done_event).?);
    try testing.expect(try c.readUntil(io, ": ping\n\n", .fromSeconds(5)));
    try testing.expectEqual(0, f.app.closes.load(.acquire));

    // The client leaves: the server sees it go, the stream ends with its
    // on_close, and its place comes back.
    c.close(io);
    try e2e.waitCount(io, &f.app.closes, 1, 5000);
    try waitNoStreams(io, &f.server);
    try testing.expectEqual(0, http.testing.inFlight(&f.server));
}

test "SSE over the network: close(key) ends the stream with its last chunk" {
    try runtime.forEachRuntime(gpa, closedByServer);
}

fn closedByServer(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "SSE close(key) over the network");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/events"));
    try e2e.waitCount(io, &f.app.subscribed, 1, 5000);
    try f.publish(io, .{ .data = "last" });
    f.live.close(io, "all");
    // The whole response: the head, the event, the last chunk.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try c.readResponse(io, arena.allocator(), .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("text/event-stream", res.header("content-type").?);
    try testing.expectEqualStrings("data: \"last\"\n\n", res.body);
    try e2e.waitCount(io, &f.app.closes, 1, 5000);
    try waitNoStreams(io, &f.server);
    // The stream ended whole, so the connection stays: it serves the next
    // request.
    try c.send(io, get("/hello"));
    const next = try c.readResponse(io, arena.allocator(), .{});
    try testing.expectEqual(200, next.status);
    try testing.expectEqualStrings("hello", next.body);
}

test "SSE over the network: to an HTTP/1.0 client the stream goes until the connection closes" {
    try runtime.forEachRuntime(gpa, http10Stream);
}

fn http10Stream(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "SSE to an HTTP/1.0 client");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, "GET /events HTTP/1.0\r\n\r\n");
    try e2e.waitCount(io, &f.app.subscribed, 1, 5000);
    try f.publish(io, .{ .data = "one" });
    try f.publish(io, .{ .data = "two" });
    f.live.close(io, "all");
    // No chunks for HTTP/1.0: the events, then the end of the connection.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try c.readResponse(io, arena.allocator(), .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqual(null, res.header("transfer-encoding"));
    try testing.expectEqual(null, res.header("content-length"));
    try testing.expectEqualStrings("close", res.header("connection").?);
    try testing.expectEqualStrings("data: \"one\"\n\ndata: \"two\"\n\n", res.body);
    try e2e.waitCount(io, &f.app.closes, 1, 5000);
    try waitNoStreams(io, &f.server);
}

/// An event of `slowClient`.
const piece: [64 << 10]u8 = @splat('s');

test "SSE over the network: a client that reads nothing holds close(key) until the write timeout" {
    try runtime.forEachRuntime(gpa, slowClient);
}

fn slowClient(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "SSE close(key) and a slow client");
    defer dog.stop(io);
    var f: Fixture = undefined;
    // A queue that takes all the events, and a write timeout of 1 s.
    try f.startWith(io, .{ .queue = .{ .max_events = 1 << 20, .max_bytes = 64 << 20 } }, .{ .write = .fromSeconds(1) });
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/events"));
    try e2e.waitCount(io, &f.app.subscribed, 1, 5000);
    // 16 MiB of events that the client never reads: more than the buffers
    // of the connection hold, so the stream's write waits.
    for (0..256) |_| try f.publish(io, .{ .data = @as([]const u8, &piece) });
    // close(key) is soft: the stream first sends what was published
    // before it, so it stays open...
    const closed_at = Io.Clock.awake.now(io);
    f.live.close(io, "all");
    try io.sleep(.fromMilliseconds(200), .awake);
    if (f.app.closes.load(.acquire) != 0) {
        std.debug.print("the stream ended within 200 ms of close(key): 16 MiB fit the buffers of the connection (zio x{d})\n", .{runtime.executors});
        return error.TestStreamNotHeld;
    }
    try testing.expectEqual(1, http.testing.openStreams(&f.server));
    // ...but only until a write sends nothing for the write timeout: then
    // the stream is cut. The writes before the one that waits may still
    // send a little, on Windows for a while.
    try e2e.waitCount(io, &f.app.closes, 1, 10_000);
    try e2e.expectWithin("close(key) held by a client that reads nothing", e2e.sinceMs(io, closed_at), 200, 1000 + 4000);
    try waitNoStreams(io, &f.server);
}
