//! SSE on `http.native` over loopback TCP, on zio: the head of a stream at
//! once, events in the order they were published, a heartbeat while none
//! comes, the end of the stream when the client leaves, and its last chunk
//! when the server closes it. Each scenario runs on one executor, then on
//! four.

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
    } });

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
        f.live = .init(gpa, .{});
        errdefer f.live.deinit(io);
        f.app = .{ .live = &f.live };
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{ .backend = f.native.backend(), .controllers = .{&f.app} });
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
}
