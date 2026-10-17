//! Request bodies on `http.native` over loopback TCP, on zio: bodies by
//! length and chunked, `Expect: 100-continue`, early responses that leave
//! a body unread (and the request after it whole), the limit of
//! `ctx.body()`, the answers to a body that fails, and the memory a
//! connection keeps. Each scenario runs on one executor, then on four.

const std = @import("std");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");
const e2e = @import("native.zig");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;
const get = e2e.get;

/// The application of the scenarios. Every handler counts its request in
/// `served`, so a byte of a body taken for a request would show.
const App = struct {
    served: std.atomic.Value(u32) = .init(0),
    /// Requests of `hold` that saw their cancelation, and when the last
    /// one did, in nanoseconds of the awake clock.
    canceled: std.atomic.Value(u32) = .init(0),
    canceled_at: std.atomic.Value(i64) = .init(0),

    pub const http_routes = http.routes(.{ .methods = .{
        .echo = http.post("/echo", .{ .max_body_bytes = 2 << 20 }),
        .small = http.post("/small", .{ .max_body_bytes = 16 }),
        .late = http.post("/late", .{}),
        .early = http.post("/early", .{}),
        .hold = http.post("/hold", .{}),
        .count = http.get("/count", .{}),
    } });

    /// The length of the body and its FNV-1a hash.
    pub fn echo(self: *App, ctx: *http.Context) !void {
        _ = self.served.fetchAdd(1, .monotonic);
        const body = try ctx.body();
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{d} {x}", .{ body.len, std.hash.Fnv1a_64.hash(body) }));
    }

    /// `echo` within 16 bytes.
    pub fn small(self: *App, ctx: *http.Context) !void {
        return self.echo(ctx);
    }

    /// `echo` after 100 ms of work.
    pub fn late(self: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromMilliseconds(100), .awake);
        return self.echo(ctx);
    }

    /// 401 without a look at the body.
    pub fn early(self: *App, ctx: *http.Context) !void {
        _ = self.served.fetchAdd(1, .monotonic);
        _ = ctx.response.status(401);
    }

    /// Reads the body, then works five seconds, unless the request is
    /// canceled.
    pub fn hold(self: *App, ctx: *http.Context) !void {
        _ = self.served.fetchAdd(1, .monotonic);
        _ = try ctx.body();
        ctx.io().sleep(.fromSeconds(5), .awake) catch |err| {
            self.canceled_at.store(@intCast(Io.Clock.awake.now(ctx.io()).nanoseconds), .monotonic);
            _ = self.canceled.fetchAdd(1, .release);
            return err;
        };
    }

    /// How many requests the server has served, this one counted.
    pub fn count(self: *App, ctx: *http.Context) !void {
        const n = self.served.fetchAdd(1, .monotonic) + 1;
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{d}", .{n}));
    }
};

const Options = struct {
    limits: http.native.Limits = .{},
    timeouts: http.native.Timeouts = .{},
    /// What the connections of the backend allocate from.
    backend_gpa: std.mem.Allocator = gpa,
};

/// A server of `App` on `http.native`, on a free port of loopback. It
/// stays where `start` put it.
const Fixture = struct {
    app: App,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io, options: Options) !void {
        f.app = .{};
        f.native = try .init(options.backend_gpa, .{ .address = "127.0.0.1", .port = 0, .limits = options.limits, .timeouts = options.timeouts });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{ .backend = f.native.backend(), .controllers = .{&f.app} });
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

/// The head of a POST of `length` bytes to `target`.
fn postHead(a: std.mem.Allocator, target: []const u8, length: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: test\r\nContent-Length: {d}\r\n\r\n", .{ target, length });
}

/// The head of a chunked POST to `target`.
fn chunkedHead(a: std.mem.Allocator, target: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n", .{target});
}

/// `data` in chunks of `size` bytes, then the last chunk.
fn chunked(a: std.mem.Allocator, data: []const u8, size: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = data;
    while (rest.len > 0) {
        const n = @min(size, rest.len);
        try out.print(a, "{x}\r\n", .{n});
        try out.appendSlice(a, rest[0..n]);
        try out.appendSlice(a, "\r\n");
        rest = rest[n..];
    }
    try out.appendSlice(a, "0\r\n\r\n");
    return out.items;
}

/// `len` bytes that differ from one place to the next, so a byte lost or
/// moved changes the hash.
fn pattern(a: std.mem.Allocator, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    for (out, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 9));
    return out;
}

/// A request to /count: bodies made of it would count if they were taken
/// for requests.
const fake_request = get("/count");

/// `len` bytes of `fake_request` over and over.
fn requestLike(a: std.mem.Allocator, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    for (out, 0..) |*b, i| b.* = fake_request[i % fake_request.len];
    return out;
}

/// The answer of `echo` to `body`.
fn expectEcho(res: raw.Response, body: []const u8) !void {
    try testing.expectEqual(200, res.status);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "{d} {x}", .{ body.len, std.hash.Fnv1a_64.hash(body) }), res.body);
}

/// The backend's short answer to a body that failed: `status`, its reason
/// as text, `Connection: close`, then the end of the connection.
fn expectBodyFailure(c: *raw.Client, io: Io, res: raw.Response, status: u16) !void {
    try testing.expectEqual(status, res.status);
    try testing.expectEqualStrings("text/plain; charset=utf-8", res.header("content-type").?);
    try testing.expectEqualStrings(res.reason, res.body);
    try testing.expectEqualStrings("close", res.header("connection").?);
    try c.expectEnd(io, .fromSeconds(2));
}

// Task 37: reading bodies.

test "a body arrives whole, by length and chunked" {
    try runtime.forEachRuntime(gpa, wholeBodies);
}

fn wholeBodies(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a body arrives whole");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try f.connect(io);
    defer c.close(io);

    // By length: in the write of the head, then larger than the buffer of
    // the connection and those of the sockets.
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\nhello");
    try expectEcho(try c.readResponse(io, a, .{}), "hello");
    const big = try pattern(a, 300 << 10);
    try c.send(io, try postHead(a, "/echo", big.len));
    try c.send(io, big);
    try expectEcho(try c.readResponse(io, a, .{}), big);

    // Chunked: extensions, and trailers that are read and dropped.
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5;name=\"v 1\";flag\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: 1\r\nX-More: 2\r\n\r\n");
    try expectEcho(try c.readResponse(io, a, .{}), "hello world");
    try c.send(io, try chunkedHead(a, "/echo"));
    try c.send(io, try chunked(a, big, 1000));
    try expectEcho(try c.readResponse(io, a, .{}), big);
    // Chunks of one byte: a step of the decoder for each.
    try c.send(io, try chunkedHead(a, "/echo"));
    try c.send(io, try chunked(a, big[0..3000], 1));
    try expectEcho(try c.readResponse(io, a, .{}), big[0..3000]);

    // In pieces of 7 bytes with pauses: reads cut the sizes, the data and
    // the line ends anywhere.
    const body = big[0..4000];
    for ([_][]const u8{ try postHead(a, "/echo", body.len), try chunkedHead(a, "/echo") }, [_][]const u8{ body, try chunked(a, body, 333) }) |head, wire| {
        try c.send(io, head);
        var i: usize = 0;
        while (i < wire.len) : (i += 7) {
            try c.send(io, wire[i..@min(i + 7, wire.len)]);
            if (i % 700 == 0) try io.sleep(.fromMilliseconds(1), .awake);
        }
        try expectEcho(try c.readResponse(io, a, .{}), body);
    }

    // An empty body by length and chunked.
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n");
    try expectEcho(try c.readResponse(io, a, .{}), "");
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n");
    try expectEcho(try c.readResponse(io, a, .{}), "");

    // Every byte of the bodies was taken: the connection serves on, and
    // nothing else comes.
    try c.send(io, get("/count"));
    try testing.expectEqualStrings("10", (try c.readResponse(io, a, .{})).body);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(30)));
}

test "Expect: 100-continue: 100 comes at the first read and never without one" {
    try runtime.forEachRuntime(gpa, continueAtFirstRead);
}

fn continueAtFirstRead(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "Expect: 100-continue");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try f.connect(io);
    defer c.close(io);

    // The head alone: nothing while the handler works, 100 when it reads,
    // then the body and the response.
    try c.send(io, "POST /late HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n");
    try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
    const go_on = try c.readResponse(io, a, .{});
    try testing.expectEqual(100, go_on.status);
    try testing.expectEqualStrings("Continue", go_on.reason);
    try testing.expectEqual(0, go_on.headers.len);
    try c.send(io, "hello");
    try expectEcho(try c.readResponse(io, a, .{}), "hello");
    // Chunked, the same.
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectEqual(100, (try c.readResponse(io, a, .{})).status);
    try c.send(io, "5\r\nhello\r\n0\r\n\r\n");
    try expectEcho(try c.readResponse(io, a, .{}), "hello");

    // No 100 without Expect, for an empty body, or to HTTP/1.0, which
    // cannot ask for it: the first response is the final one.
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\nhello");
    try expectEcho(try c.readResponse(io, a, .{}), "hello");
    try c.send(io, "POST /echo HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 0\r\n\r\n");
    try expectEcho(try c.readResponse(io, a, .{}), "");
    var old = try f.connect(io);
    defer old.close(io);
    try old.send(io, "POST /echo HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");
    try expectEcho(try old.readResponse(io, a, .{}), "hello");
    try old.expectEnd(io, .fromSeconds(2));

    try c.send(io, get("/count"));
    try testing.expectEqualStrings("6", (try c.readResponse(io, a, .{})).body);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(30)));
}

// Task 38: early responses.

test "a GET with a body: the body is dropped and the next request parses" {
    try runtime.forEachRuntime(gpa, getWithBody);
}

fn getWithBody(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a GET with a body");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try f.connect(io);
    defer c.close(io);

    // Bodies that read as requests, by length and chunked, each with a
    // request after it in the same write.
    const by_length = std.fmt.comptimePrint("GET /count HTTP/1.1\r\nHost: test\r\nContent-Length: {d}\r\n\r\n", .{fake_request.len}) ++ fake_request;
    const by_chunks = "GET /count HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        std.fmt.comptimePrint("{x}\r\n", .{fake_request.len}) ++ fake_request ++ "\r\n0\r\n\r\n";
    try c.send(io, by_length ++ get("/count") ++ by_chunks ++ get("/count"));
    for ([_][]const u8{ "1", "2", "3", "4" }) |n| try testing.expectEqualStrings(n, (try c.readResponse(io, a, .{})).body);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
    try testing.expectEqual(4, f.app.served.load(.monotonic));
}

test "an early answer to Expect: 100-continue closes without reading the body" {
    try runtime.forEachRuntime(gpa, earlyAnswerToContinue);
}

fn earlyAnswerToContinue(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "an early answer to Expect: 100-continue");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "Content-Length: 5", "Transfer-Encoding: chunked" }) |framing| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.fmt.allocPrint(a, "POST /early HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\n{s}\r\n\r\n", .{framing}));
        // The final answer, without a 100 before it.
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(401, res.status);
        try testing.expectEqualStrings("close", res.header("connection").?);
        try c.expectEnd(io, .fromSeconds(2));
    }
}

test "an early response skips the unread body and the pipelined request after it stays whole" {
    try runtime.forEachRuntime(gpa, earlyResponses);
}

fn earlyResponses(io: Io) !void {
    // Review focus 1.
    var dog = try e2e.Watchdog.start(io, "an early response skips the unread body");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ten = try requestLike(a, 10 << 10);
    const hundred = try requestLike(a, 100 << 10);

    // (a) 10 KiB by length, unread, and a GET in the same write: the
    // server drops the body, and the next response is the GET's.
    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try postHead(a, "/early", ten.len), ten, get("/count") }));
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(401, res.status);
        try testing.expectEqual(null, res.header("connection"));
        try testing.expectEqualStrings("2", (try c.readResponse(io, a, .{})).body);
        try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
    }
    // (b) The same, chunked.
    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try chunkedHead(a, "/early"), try chunked(a, ten, 1000), get("/count") }));
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(401, res.status);
        try testing.expectEqual(null, res.header("connection"));
        try testing.expectEqualStrings("4", (try c.readResponse(io, a, .{})).body);
        try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
    }
    // (c) 100 KiB by length: more than the server drops, so the response
    // says Connection: close, and the connection ends.
    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try postHead(a, "/early", hundred.len), hundred[0 .. 10 << 10] }));
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(401, res.status);
        try testing.expectEqualStrings("close", res.header("connection").?);
        try c.expectEnd(io, .fromSeconds(2));
    }
    // (d) 100 KiB chunked: its size is unknown when the response goes out,
    // so the response keeps the connection; past 64 KiB of dropped body it
    // ends.
    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try chunkedHead(a, "/early"), try chunked(a, hundred, 1000), get("/count") }));
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(401, res.status);
        try testing.expectEqual(null, res.header("connection"));
        try c.expectEnd(io, .fromSeconds(2));
    }
    // Every request that reached a handler was sent as one.
    try testing.expectEqual(6, f.app.served.load(.monotonic));
}

// Task 39: ctx.body.

test "Expect: 100-continue over the limit: 413 without 100" {
    try runtime.forEachRuntime(gpa, continueOverLimit);
}

fn continueOverLimit(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "Expect: 100-continue over the limit");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, "POST /small HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 17\r\n\r\n");
        const res = try c.readResponse(io, a, .{});
        try testing.expectEqual(413, res.status);
        try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
        try testing.expectEqualStrings("close", res.header("connection").?);
        try c.expectEnd(io, .fromSeconds(2));
    }
    // Within the limit, 100 and the body.
    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, "POST /small HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 16\r\n\r\n");
    try testing.expectEqual(100, (try c.readResponse(io, a, .{})).status);
    try c.send(io, "0123456789abcdef");
    try expectEcho(try c.readResponse(io, a, .{}), "0123456789abcdef");
    // Over it without Expect: 413, by length before a byte is read, and
    // chunked once it crosses it; the rest is dropped, and the connection
    // serves on.
    try c.send(io, "POST /small HTTP/1.1\r\nHost: test\r\nContent-Length: 17\r\n\r\n0123456789abcdefg");
    try testing.expectEqual(413, (try c.readResponse(io, a, .{})).status);
    try c.send(io, "POST /small HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "8\r\n01234567\r\n8\r\n89abcdef\r\n1\r\ng\r\n8\r\nhijklmno\r\n0\r\n\r\n");
    try testing.expectEqual(413, (try c.readResponse(io, a, .{})).status);
    try c.send(io, get("/count"));
    try testing.expectEqualStrings("5", (try c.readResponse(io, a, .{})).body);
}

test "a connection keeps at most 64 KiB of arena after a large request" {
    try runtime.forEachRuntime(gpa, arenaKeepsLittle);
}

fn arenaKeepsLittle(io: Io) !void {
    // Review focus 5.
    var dog = try e2e.Watchdog.start(io, "a connection keeps at most 64 KiB of arena");
    defer dog.stop(io);
    var counting: CountingAllocator = .init(gpa);
    var f: Fixture = undefined;
    try f.start(io, .{ .backend_gpa = counting.allocator() });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const baseline = counting.liveBytes();

    var c = try f.connect(io);
    defer c.close(io);
    const big = try pattern(a, 1 << 20);
    try c.send(io, try postHead(a, "/echo", big.len));
    try c.send(io, big);
    try expectEcho(try c.readResponse(io, a, .{}), big);
    for (0..1000) |_| {
        try c.send(io, get("/count"));
        _ = try c.readResponse(io, a, .{});
    }
    // The open connection holds its buffer, its fields and the arena it
    // keeps between requests.
    const limits: http.native.Limits = .{};
    const buffers = limits.max_head_bytes + @as(usize, limits.max_header_fields) * @sizeOf([2][]const u8);
    const bound = (64 << 10) + buffers + 1024;
    const kept = counting.liveBytes() -| baseline;
    if (kept > bound) {
        std.debug.print("the connection keeps {d} bytes, more than {d} (zio x{d})\n", .{ kept, bound, runtime.executors });
        return error.TestConnectionKeepsTooMuch;
    }
}

test "a client that leaves after its body was read cancels the request" {
    try runtime.forEachRuntime(gpa, leavesAfterBody);
}

fn leavesAfterBody(io: Io) !void {
    // Once ctx.body() has read the body to its end, the watcher reads the
    // connection, so it sees the client leave.
    var dog = try e2e.Watchdog.start(io, "a client that leaves after its body");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    for ([_][]const u8{
        "POST /hold HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\nhello",
        "POST /hold HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    }, 1..) |request, n| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, request);
        try e2e.waitCount(io, &f.app.served, @intCast(n), 2000);
        // The handler has the body and works.
        try io.sleep(.fromMilliseconds(20), .awake);
        const left: i64 = @intCast(Io.Clock.awake.now(io).nanoseconds);
        c.close(io);
        try e2e.waitCount(io, &f.app.canceled, @intCast(n), 2000);
        const ms = @divTrunc(f.app.canceled_at.load(.monotonic) - left, std.time.ns_per_ms);
        try e2e.expectWithin("the handler saw Canceled after the client left", ms, 0, 100);
        try e2e.waitIdle(io, &f.server);
    }
}

// Task 40: body failures.

test "a body that stalls longer than timeouts.body gets 408 and close" {
    try runtime.forEachRuntime(gpa, stalledBody);
}

fn stalledBody(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a body that stalls");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .timeouts = .{ .body = .fromMilliseconds(200) } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Half a body by length, and a body that stops between two chunks.
    for ([_][]const u8{
        "POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\n\r\nhello",
        "POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n",
    }) |request| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, request);
        const start = Io.Clock.awake.now(io);
        const res = try c.readResponse(io, a, .{});
        try e2e.expectWithin("408 after the body stalled", e2e.sinceMs(io, start), 150, 700);
        try expectBodyFailure(&c, io, res, 408);
    }
    try testing.expectEqual(2, f.app.served.load(.monotonic));
}

test "a malformed chunk mid-body gets 400 and close" {
    try runtime.forEachRuntime(gpa, malformedChunk);
}

fn malformedChunk(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a malformed chunk mid-body");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A size that is not hex, data without its CRLF, a space before a size.
    for ([_][]const u8{ "5\r\nhello\r\nZZ\r\nhello\r\n0\r\n\r\n", "5\r\nhelloXX\r\n0\r\n\r\n", "5\r\nhello\r\n 3\r\nabc\r\n0\r\n\r\n" }) |body| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try chunkedHead(a, "/echo"), body }));
        try expectBodyFailure(&c, io, try c.readResponse(io, a, .{}), 400);
    }
}

test "chunk extensions over 4 KiB get 400 and close" {
    try runtime.forEachRuntime(gpa, longChunkMeta);
}

fn longChunkMeta(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "chunk extensions over 4 KiB");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // ";e=" and 4 093 bytes: 4 KiB of extension, the most there may be.
    const at_limit = "1;e=" ++ @as([4093]u8, @splat('x')) ++ "\r\nx\r\n0\r\n\r\n";
    {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try chunkedHead(a, "/echo"), at_limit }));
        try expectEcho(try c.readResponse(io, a, .{}), "x");
    }
    // A byte more, an extension longer than the buffer of the connection,
    // and trailer fields over the limit.
    for ([_][]const u8{
        "1;e=" ++ @as([4094]u8, @splat('x')) ++ "\r\nx\r\n0\r\n\r\n",
        "1;e=" ++ @as([20 << 10]u8, @splat('x')) ++ "\r\nx\r\n0\r\n\r\n",
        "1\r\nx\r\n0\r\nX-Pad: " ++ @as([4100]u8, @splat('p')) ++ "\r\n\r\n",
    }) |body| {
        var c = try f.connect(io);
        defer c.close(io);
        try c.send(io, try std.mem.concat(a, u8, &.{ try chunkedHead(a, "/echo"), body }));
        try expectBodyFailure(&c, io, try c.readResponse(io, a, .{}), 400);
    }
}
