//! `http.native` over loopback TCP on zio: connections and their limit,
//! the stop, the heads and the answers of the backend, responses,
//! keep-alive and pipelining, and the watcher that sees a client leave.
//! Each scenario runs on one executor, then on four, with a watchdog that
//! ends the run (exit code 4) when it hangs. The other files of e2e/ share
//! its helpers.

const std = @import("std");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;

const Todo = struct { id: u64, title: []const u8 };

/// A body larger than the buffers of a loopback socket.
const big_body: [256 << 10]u8 = @splat('b');

/// The application of the scenarios. Its servers turn the strict error
/// check off: `fail` answers 500 with an error that no error handler maps.
const App = struct {
    /// Requests that entered `sleep` or `gated`.
    entered: std.atomic.Value(u32) = .init(0),
    /// Requests of `sleep` that saw their cancelation, and when the last
    /// one did, in nanoseconds of the awake clock.
    canceled: std.atomic.Value(u32) = .init(0),
    canceled_at: std.atomic.Value(i64) = .init(0),
    /// Opens `gated`.
    gate: Io.Event = .unset,
    /// Requests of `upload` whose body did not come whole.
    body_failures: std.atomic.Value(u32) = .init(0),

    pub const http_routes = http.routes(.{ .methods = .{
        .hello = http.get("/hello", .{}),
        .empty = http.get("/empty", .{}),
        .cached = http.get("/cached", .{}),
        .echo = http.get("/echo/{id}", .{}),
        .slow = http.get("/slow/{id}", .{}),
        .todo = http.get("/todo", .{}),
        .header = http.get("/header", .{}),
        .big = http.get("/big", .{}),
        .fail = http.get("/fail", .{}),
        .sleep = http.get("/sleep", .{}),
        .gated = http.get("/gated", .{}),
        .upload = http.post("/upload", .{}),
    } });

    pub fn hello(_: *App, ctx: *http.Context) !void {
        try ctx.response.text("hello");
    }
    pub fn empty(_: *App, _: *http.Context) !void {}
    pub fn cached(_: *App, ctx: *http.Context) !void {
        try ctx.response.setHeader("etag", "\"v1\"");
        _ = ctx.response.status(304);
    }
    /// The path as it came.
    pub fn echo(_: *App, ctx: *http.Context) !void {
        try ctx.response.text(ctx.request.path);
    }
    /// The path, after 50 ms.
    pub fn slow(_: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromMilliseconds(50), .awake);
        try ctx.response.text(ctx.request.path);
    }
    pub fn todo(_: *App, _: *http.Context) !http.Json(Todo) {
        return .{ .value = .{ .id = 7, .title = "Buy milk" } };
    }
    pub fn header(_: *App, ctx: *http.Context) !void {
        try ctx.response.setHeader("x-name", ctx.request.header("x-name") orelse "none");
    }
    pub fn big(_: *App, ctx: *http.Context) !void {
        try ctx.response.text(&big_body);
    }
    pub fn fail(_: *App, _: *http.Context) !void {
        return error.TodoNotFound;
    }
    /// Five seconds of work, unless the request is canceled.
    pub fn sleep(self: *App, ctx: *http.Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        ctx.io().sleep(.fromSeconds(5), .awake) catch |err| {
            self.canceled_at.store(nowNs(ctx.io()), .monotonic);
            _ = self.canceled.fetchAdd(1, .release);
            return err;
        };
        try ctx.response.text("slept");
    }
    pub fn gated(self: *App, ctx: *http.Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try self.gate.wait(ctx.io());
        try ctx.response.text("opened");
    }
    /// The length of the body; a body its client cut short counts in
    /// `body_failures`, and the response goes to nobody.
    pub fn upload(self: *App, ctx: *http.Context) !void {
        const body = ctx.body() catch |err| switch (err) {
            error.ReadFailed => {
                _ = self.body_failures.fetchAdd(1, .release);
                return;
            },
            else => |e| return e,
        };
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{d}", .{body.len}));
    }
};

fn nowNs(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

pub fn sinceMs(io: Io, start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
}

/// Fails unless `ms` lies in [min, max).
pub fn expectWithin(what: []const u8, ms: i64, min: i64, max: i64) !void {
    if (ms < min or ms >= max) {
        std.debug.print("{s}: {d} ms, expected [{d}, {d}) ms (zio x{d})\n", .{ what, ms, min, max, runtime.executors });
        return error.TestUnexpectedTime;
    }
}

/// Ends the process with code 4 when a scenario runs longer than its time:
/// a hang fails at once, by name.
pub const Watchdog = struct {
    future: Io.Future(void),

    pub fn start(io: Io, name: []const u8) !Watchdog {
        return startFor(io, name, 60);
    }

    /// The same with a time of `seconds`, for the scenarios under load.
    pub fn startFor(io: Io, name: []const u8, seconds: i64) !Watchdog {
        return .{ .future = try io.concurrent(watch, .{ io, name, seconds }) };
    }

    pub fn stop(w: *Watchdog, io: Io) void {
        w.future.cancel(io);
    }

    fn watch(io: Io, name: []const u8, seconds: i64) void {
        io.sleep(.fromSeconds(seconds), .awake) catch return;
        std.debug.print("\"{s}\" still runs after {d} s on zio x{d}: a hang\n", .{ name, seconds, runtime.executors });
        std.process.exit(4);
    }
};

const Settings = struct {
    limits: http.native.Limits = .{},
    timeouts: http.native.Timeouts = .{},
};

/// A server of `App` on `http.native`, on a free port of loopback. It
/// stays where `start` put it.
const Fixture = struct {
    app: App,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io, settings: Settings) !void {
        f.app = .{};
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0, .limits = settings.limits, .timeouts = settings.timeouts });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{ .backend = f.native.backend(), .controllers = .{&f.app}, .strict_errors = false });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.native.deinit();
    }

    fn connect(f: *Fixture, io: Io) !raw.Client {
        return raw.Client.connect(io, gpa, f.native.port());
    }
};

pub inline fn get(comptime target: []const u8) []const u8 {
    return "GET " ++ target ++ " HTTP/1.1\r\nHost: test\r\n\r\n";
}

/// Waits until `count` reaches `n`, `limit_ms` at most.
pub fn waitCount(io: Io, count: *const std.atomic.Value(u32), n: u32, limit_ms: i64) !void {
    const start = Io.Clock.awake.now(io);
    while (count.load(.acquire) < n) {
        if (sinceMs(io, start) > limit_ms) return error.TestCountNotReached;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until the server has no request at work, a second at most.
pub fn waitIdle(io: Io, server: *const http.Server) !void {
    const start = Io.Clock.awake.now(io);
    while (http.testing.inFlight(server) != 0) {
        if (sinceMs(io, start) > 1000) return error.TestRequestsStillAtWork;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

inline fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

/// `Ddd, DD Mon YYYY HH:MM:SS GMT`.
fn expectImfDate(value: []const u8) !void {
    try testing.expectEqual(29, value.len);
    const days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var day_ok = false;
    for (days) |d| day_ok = day_ok or std.mem.eql(u8, value[0..3], d);
    var month_ok = false;
    for (months) |m| month_ok = month_ok or std.mem.eql(u8, value[8..11], m);
    try testing.expect(day_ok and month_ok);
    try testing.expectEqualStrings(", ", value[3..5]);
    try testing.expectEqualStrings(" GMT", value[25..29]);
    for ([_]usize{ 5, 6, 12, 13, 14, 15, 17, 18, 20, 21, 23, 24 }) |i| try testing.expect(std.ascii.isDigit(value[i]));
    try testing.expect(value[19] == ':' and value[22] == ':');
}

// Task 31: connections, their limit and the stop.

test "max_connections: the connection over the limit waits until one closes" {
    try runtime.forEachRuntime(gpa, maxConnections);
}

fn maxConnections(io: Io) !void {
    var dog = try Watchdog.start(io, "max_connections");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .limits = .{ .max_connections = 2 } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var first = try f.connect(io);
    defer first.close(io);
    var second = try f.connect(io);
    defer second.close(io);
    for ([_]*raw.Client{ &first, &second }) |c| {
        try c.send(io, get("/hello"));
        try testing.expectEqual(200, (try c.readResponse(io, a, .{})).status);
    }
    // The third connects, in the kernel's queue, and gets no answer while
    // two are open.
    var third = try f.connect(io);
    defer third.close(io);
    try third.send(io, get("/hello"));
    try testing.expectError(error.Timeout, third.readResponse(io, a, .{ .timeout = .fromMilliseconds(300) }));
    first.close(io);
    const res = try third.readResponse(io, a, .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("hello", res.body);
}

test "stop: idle connections close at once, a busy one ends with Connection: close" {
    try runtime.forEachRuntime(gpa, stopClosesIdleThenBusy);
}

fn stopClosesIdleThenBusy(io: Io) !void {
    var dog = try Watchdog.start(io, "stop");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // One connection kept alive after its response, one new and silent, one
    // busy in a handler.
    var idle = try f.connect(io);
    defer idle.close(io);
    try idle.send(io, get("/hello"));
    try testing.expectEqual(200, (try idle.readResponse(io, a, .{})).status);
    var silent = try f.connect(io);
    defer silent.close(io);
    var busy = try f.connect(io);
    defer busy.close(io);
    try busy.send(io, get("/gated"));
    try waitCount(io, &f.app.entered, 1, 2000);

    const stop = Io.Clock.awake.now(io);
    f.server.requestStop(io);
    try idle.expectEnd(io, .fromSeconds(2));
    try silent.expectEnd(io, .fromSeconds(2));
    try expectWithin("idle connections closed after the stop", sinceMs(io, stop), 0, 500);
    try testing.expectEqual(http.Server.State.draining, f.server.state());

    f.app.gate.set(io);
    const res = try busy.readResponse(io, a, .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("opened", res.body);
    try testing.expectEqualStrings("close", res.header("connection").?);
    try busy.expectEnd(io, .fromSeconds(2));
    try f.server.wait(io);
    try testing.expectEqual(http.Server.State.stopped, f.server.state());
}

test "connection slots come back after resets" {
    try runtime.forEachRuntime(gpa, slotsComeBack);
}

/// Where a connection of `dropConnections` ends.
const Drop = enum { mid_head, mid_body, mid_response };

/// Connections a worker opens and drops: one ends mid-head, the next
/// mid-body, the next mid-response, and so on.
fn dropConnections(io: Io, port: u16, count: usize, failures: *std.atomic.Value(u32)) void {
    for (0..count) |i| {
        dropOne(io, port, @fromBackingInt(@intCast(i % 3))) catch {
            _ = failures.fetchAdd(1, .monotonic);
        };
    }
}

fn dropOne(io: Io, port: u16, where: Drop) !void {
    var c = try raw.Client.connect(io, gpa, port);
    defer c.close(io);
    switch (where) {
        .mid_head => try c.send(io, "GET /hello HTTP/1.1\r\nHost: test\r\nX-Pad: abc"),
        // The handler reads the body, and the close cuts it.
        .mid_body => try c.send(io, "POST /upload HTTP/1.1\r\nHost: test\r\nContent-Length: 1000\r\n\r\npartial"),
        .mid_response => {
            try c.send(io, get("/big"));
            // Some of the response has come: the close cuts it.
            if (!try c.waitData(io, .fromSeconds(5))) return error.TestNoResponse;
        },
    }
}

fn slotsComeBack(io: Io) !void {
    var dog = try Watchdog.start(io, "connection slots come back");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .limits = .{ .max_connections = 4 } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 2 000 connections from 16 workers, each closed mid-head, mid-body
    // or mid-response.
    var failures: std.atomic.Value(u32) = .init(0);
    var workers: Io.Group = .init;
    for (0..16) |_| try workers.concurrent(io, dropConnections, .{ io, f.native.port(), 125, &failures });
    try workers.await(io);
    try testing.expectEqual(0, failures.load(.monotonic));
    // Each body cut short reached its handler as ReadFailed.
    const mid_body: u32 = 16 * 42;
    try waitCount(io, &f.app.body_failures, mid_body, 5000);
    try testing.expectEqual(mid_body, f.app.body_failures.load(.acquire));

    // Every slot is free again: four clients at once are all served.
    var clients: [4]raw.Client = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |*c| c.close(io);
    for (&clients) |*c| {
        c.* = try f.connect(io);
        opened += 1;
        try c.send(io, get("/hello"));
    }
    for (&clients) |*c| try testing.expectEqual(200, (try c.readResponse(io, a, .{})).status);
    try waitIdle(io, &f.server);
}

// Task 32: heads and the answers of the backend.

test "each parse error gets its status and the connection closes" {
    try runtime.forEachRuntime(gpa, parseErrors);
}

fn parseErrors(io: Io) !void {
    var dog = try Watchdog.start(io, "parse errors");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .limits = .{ .max_head_bytes = 1024, .max_header_fields = 8, .max_target_bytes = 256 } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const long_target = "GET /" ++ @as([300]u8, @splat('t')) ++ " HTTP/1.1\r\nHost: test\r\n\r\n";
    const long_field = "GET / HTTP/1.1\r\nHost: test\r\nX-Pad: " ++ @as([1100]u8, @splat('p')) ++ "\r\n\r\n";
    const many_fields = "GET / HTTP/1.1\r\nHost: test\r\n" ++ repeat("X-A: 1\r\n", 8) ++ "\r\n";
    const cases = [_]struct { u16, []const u8 }{
        .{ 400, "GET / HTTP/1.1\r\n\r\n" }, // no Host
        .{ 400, "POST / HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello" },
        .{ 400, "GET / HTTP/1.1\r\nHost : test\r\n\r\n" }, // a space before ':'
        .{ 501, "POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: gzip\r\n\r\n" },
        .{ 414, long_target },
        .{ 431, long_field },
        .{ 431, many_fields },
        .{ 417, "GET / HTTP/1.1\r\nHost: test\r\nExpect: 200-ok\r\n\r\n" },
        .{ 505, "GET / HTTP/2.0\r\nHost: test\r\n\r\n" },
    };
    for (cases) |case| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, case[1]);
        const res = try c.readResponse(io, a, .{});
        testing.expectEqual(case[0], res.status) catch |err| {
            std.debug.print("{d} expected for {s}\n", .{ case[0], case[1][0..@min(case[1].len, 60)] });
            return err;
        };
        try testing.expectEqualStrings("close", res.header("connection").?);
        try testing.expectEqualStrings("text/plain; charset=utf-8", res.header("content-type").?);
        try testing.expectEqualStrings(res.reason, res.body);
        try expectImfDate(res.header("date").?);
        try c.expectEnd(io, .fromSeconds(2));
    }
}

test "a silent new connection closes without 408" {
    try runtime.forEachRuntime(gpa, silentConnection);
}

fn silentConnection(io: Io) !void {
    var dog = try Watchdog.start(io, "silent connection");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .timeouts = .{ .header = .fromMilliseconds(300) } });
    defer f.deinit(io);
    var c = try f.connect(io);
    defer c.close(io);
    const start = Io.Clock.awake.now(io);
    try c.expectEnd(io, .fromSeconds(3));
    try expectWithin("a silent connection closed", sinceMs(io, start), 290, 1000);
}

test "an idle keep-alive connection closes after the idle timeout" {
    try runtime.forEachRuntime(gpa, idleConnection);
}

fn idleConnection(io: Io) !void {
    var dog = try Watchdog.start(io, "idle connection");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .timeouts = .{ .idle = .fromMilliseconds(300) } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/hello"));
    const res = try c.readResponse(io, arena.allocator(), .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqual(null, res.header("connection"));
    const start = Io.Clock.awake.now(io);
    try c.expectEnd(io, .fromSeconds(3));
    try expectWithin("an idle connection closed", sinceMs(io, start), 290, 1000);
}

test "a client that trickles its head gets 408 at the head deadline" {
    try runtime.forEachRuntime(gpa, trickledHead);
}

fn trickledHead(io: Io) !void {
    var dog = try Watchdog.start(io, "trickled head");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .timeouts = .{ .header = .fromMilliseconds(300) } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try f.connect(io);
    defer c.close(io);

    // One byte each 100 ms: every read of the server gets a byte, yet the
    // head is late.
    const head = get("/hello");
    const start = Io.Clock.awake.now(io);
    for (head) |byte| {
        try c.send(io, &.{byte});
        if (try c.waitData(io, .fromMilliseconds(100))) break;
    } else return error.TestNoAnswer;
    const res = try c.readResponse(io, arena.allocator(), .{});
    try expectWithin("408 after the first byte", sinceMs(io, start), 300, 450);
    try testing.expectEqual(408, res.status);
    try testing.expectEqualStrings("close", res.header("connection").?);
    try c.expectEnd(io, .fromSeconds(2));
}

// Task 33: responses.

test "Date and Content-Length on every response" {
    try runtime.forEachRuntime(gpa, dateAndLength);
}

fn dateAndLength(io: Io) !void {
    var dog = try Watchdog.start(io, "Date and Content-Length");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try f.connect(io);
    defer c.close(io);
    for ([_][]const u8{ get("/hello"), get("/todo"), get("/missing"), "POST /hello HTTP/1.1\r\nHost: test\r\n\r\n" }) |request| {
        try c.send(io, request);
        const res = try c.readResponse(io, arena.allocator(), .{});
        try expectImfDate(res.header("date").?);
        try testing.expectEqual(1, res.count("date"));
        const length = try std.fmt.parseInt(usize, res.header("content-length").?, 10);
        try testing.expectEqual(res.body.len, length);
        try testing.expectEqual(null, res.header("transfer-encoding"));
    }
}

test "HEAD, 204 and 304 have no body" {
    try runtime.forEachRuntime(gpa, noBodies);
}

fn noBodies(io: Io) !void {
    var dog = try Watchdog.start(io, "HEAD, 204 and 304");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try f.connect(io);
    defer c.close(io);

    // All at once: a byte of a body where none belongs would break the
    // response after it.
    try c.send(io, "HEAD /hello HTTP/1.1\r\nHost: test\r\n\r\n" ++ get("/empty") ++ get("/cached") ++ get("/hello"));
    const head = try c.readResponse(io, a, .{ .head_request = true });
    try testing.expectEqual(200, head.status);
    try testing.expectEqualStrings("5", head.header("content-length").?);
    const empty = try c.readResponse(io, a, .{});
    try testing.expectEqual(204, empty.status);
    try testing.expectEqual(null, empty.header("content-length"));
    try testing.expectEqual(null, empty.header("transfer-encoding"));
    const cached = try c.readResponse(io, a, .{});
    try testing.expectEqual(304, cached.status);
    try testing.expectEqualStrings("\"v1\"", cached.header("etag").?);
    try testing.expectEqual(null, cached.header("content-length"));
    const hello = try c.readResponse(io, a, .{});
    try testing.expectEqualStrings("hello", hello.body);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
}

test "HTTP/1.0: no chunked; keep-alive only when asked" {
    try runtime.forEachRuntime(gpa, http10);
}

fn http10(io: Io) !void {
    var dog = try Watchdog.start(io, "HTTP/1.0");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Without keep-alive: one response, then the end.
    var once = try f.connect(io);
    defer once.close(io);
    try once.send(io, "GET /hello HTTP/1.0\r\n\r\n");
    const res = try once.readResponse(io, a, .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("5", res.header("content-length").?);
    try testing.expectEqual(null, res.header("transfer-encoding"));
    try testing.expectEqualStrings("close", res.header("connection").?);
    try once.expectEnd(io, .fromSeconds(2));

    // With it: kept, and said so, until a request without it.
    var kept = try f.connect(io);
    defer kept.close(io);
    try kept.send(io, "GET /hello HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    const first = try kept.readResponse(io, a, .{});
    try testing.expectEqualStrings("keep-alive", first.header("connection").?);
    try testing.expectEqualStrings("hello", first.body);
    try kept.send(io, "GET /todo HTTP/1.0\r\n\r\n");
    const second = try kept.readResponse(io, a, .{});
    try testing.expectEqual(200, second.status);
    try testing.expectEqualStrings("close", second.header("connection").?);
    try kept.expectEnd(io, .fromSeconds(2));
}

// Task 34: keep-alive and pipelining.

test "two pipelined requests get two responses in order" {
    try runtime.forEachRuntime(gpa, pipelined);
}

fn pipelined(io: Io) !void {
    var dog = try Watchdog.start(io, "pipelined");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try f.connect(io);
    defer c.close(io);

    // In one write.
    try c.send(io, get("/echo/1") ++ get("/echo/2"));
    try testing.expectEqualStrings("/echo/1", (try c.readResponse(io, a, .{})).body);
    try testing.expectEqualStrings("/echo/2", (try c.readResponse(io, a, .{})).body);
    // The second while the first runs: the watcher reads it ahead and keeps
    // it for the next head.
    try c.send(io, get("/slow/a"));
    try io.sleep(.fromMilliseconds(10), .awake);
    try c.send(io, get("/echo/b"));
    try testing.expectEqualStrings("/slow/a", (try c.readResponse(io, a, .{})).body);
    try testing.expectEqualStrings("/echo/b", (try c.readResponse(io, a, .{})).body);
}

test "the same server answers the same on native and on testing" {
    try runtime.forEachRuntime(gpa, sameOnBoth);
}

const Exchange = struct {
    method: std.http.Method,
    target: []const u8,
    headers: []const [2][]const u8 = &.{},
};

const exchanges = [_]Exchange{
    .{ .method = .GET, .target = "/hello" },
    .{ .method = .HEAD, .target = "/hello" },
    .{ .method = .GET, .target = "/hello/" },
    .{ .method = .GET, .target = "/HELLO" },
    .{ .method = .GET, .target = "//hello" },
    .{ .method = .GET, .target = "/empty" },
    .{ .method = .GET, .target = "/cached" },
    .{ .method = .GET, .target = "/echo/abc" },
    .{ .method = .GET, .target = "/echo/a%7Eb?x=1" },
    .{ .method = .GET, .target = "/todo" },
    .{ .method = .HEAD, .target = "/todo" },
    .{ .method = .GET, .target = "/header", .headers = &.{.{ "X-Name", "zed" }} },
    .{ .method = .GET, .target = "/missing" },
    .{ .method = .POST, .target = "/hello" },
    .{ .method = .DELETE, .target = "/empty" },
    .{ .method = .PUT, .target = "/todo" },
    .{ .method = .OPTIONS, .target = "/hello" },
    .{ .method = .OPTIONS, .target = "*" },
    .{ .method = .GET, .target = "/fail" },
    .{ .method = .GET, .target = "/echo/%FF" },
};

fn sameOnBoth(io: Io) !void {
    var dog = try Watchdog.start(io, "the same server on native and testing");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var app: App = .{};
    var memory: http.testing.Backend = .init(gpa);
    defer memory.deinit();
    var server = try http.Server.init(gpa, .{ .backend = memory.backend(), .controllers = .{&app}, .strict_errors = false });
    defer server.deinit(io);
    try server.start(io);

    // All the requests on one connection, kept alive.
    var c = try f.connect(io);
    defer c.close(io);
    for (exchanges) |e| {
        var request: std.ArrayList(u8) = .empty;
        try request.print(a, "{t} {s} HTTP/1.1\r\nHost: test\r\n", .{ e.method, e.target });
        for (e.headers) |h| try request.print(a, "{s}: {s}\r\n", .{ h[0], h[1] });
        try request.appendSlice(a, "\r\n");
        try c.send(io, request.items);
        const wire = try c.readResponse(io, a, .{ .head_request = e.method == .HEAD });

        var mem = try memory.request(io, .{ .method = e.method, .target = e.target, .headers = e.headers });
        defer mem.deinit();

        errdefer std.debug.print("{t} {s}: native {d} {s}, testing {d} {s}\n", .{ e.method, e.target, wire.status, wire.body, mem.status, mem.body });
        try testing.expectEqual(mem.status, wire.status);
        try testing.expectEqualStrings(mem.body, wire.body);
        // The fields but Date, which only the network has, in order.
        var fields: usize = 0;
        for (wire.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "date")) continue;
            try testing.expect(fields < mem.headers.len);
            try testing.expect(std.ascii.eqlIgnoreCase(mem.headers[fields][0], h.name));
            try testing.expectEqualStrings(mem.headers[fields][1], h.value);
            fields += 1;
        }
        try testing.expectEqual(mem.headers.len, fields);
    }
}

// Task 35: the watcher.

test "the watcher cancels a request whose client left" {
    try runtime.forEachRuntime(gpa, clientLeaves);
}

fn clientLeaves(io: Io) !void {
    var dog = try Watchdog.start(io, "the watcher cancels a request whose client left");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/sleep"));
    try waitCount(io, &f.app.entered, 1, 2000);
    const left = nowNs(io);
    c.close(io);
    try waitCount(io, &f.app.canceled, 1, 2000);
    const ms = @divTrunc(f.app.canceled_at.load(.monotonic) - left, std.time.ns_per_ms);
    try expectWithin("the handler saw Canceled after the client left", ms, 0, 100);
    try waitIdle(io, &f.server);
}

test "a client that half-closes after its request is gone" {
    try runtime.forEachRuntime(gpa, halfClose);
}

fn halfClose(io: Io) !void {
    var dog = try Watchdog.start(io, "a client that half-closes");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/sleep"));
    try waitCount(io, &f.app.entered, 1, 2000);
    try c.shutdownSend(io);
    // Gone for the server: the request is canceled and gets no response.
    try waitCount(io, &f.app.canceled, 1, 2000);
    try c.expectEnd(io, .fromSeconds(2));
    try waitIdle(io, &f.server);
}
