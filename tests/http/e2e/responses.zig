//! Responses on `http.native` over loopback TCP, on zio: a body past the
//! response buffer of 16 KiB (chunked on HTTP/1.1, until the connection
//! closes on HTTP/1.0), a stream whose `flush` sends at once, a file from
//! the disk, an error after the head that cuts the response, and a client
//! that does not read, which the write timeout cuts. Each scenario runs on
//! one executor, then on four.

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

/// What `flood` writes at a time.
const piece: [64 << 10]u8 = @splat('f');

/// The application of the scenarios. Its server turns the strict error
/// check off: `download` leaves `FileNotFound` unmapped, and `broken` fails
/// with an error of its own after its head.
const App = struct {
    /// The file `download` sends, relative to the working directory.
    file_path: []const u8 = "",
    /// Opens the second part of `live`.
    gate: Io.Event = .unset,
    /// How far `live` got: 1 flushed, 2 through the gate, 3 finished; and
    /// the error that ended it, for the message of a failure.
    live_stage: std.atomic.Value(u8) = .init(0),
    live_error: ?anyerror = null,
    /// `flood` has ended, with this error; when its last write that went
    /// well ended and when the one that failed did, in nanoseconds of the
    /// awake clock.
    flood_done: std.atomic.Value(u32) = .init(0),
    flood_error: ?anyerror = null,
    last_ok_ns: i64 = 0,
    failed_ns: i64 = 0,

    pub const http_routes = http.routes(.{ .methods = .{
        .many = http.get("/todos", .{}),
        .one = http.get("/todos/one", .{}),
        .live = http.get("/live", .{}),
        .download = http.get("/file", .{}),
        .broken = http.get("/broken", .{}),
        .flood = http.get("/flood", .{}),
    } });

    /// 2 000 todos: about 90 KB of JSON, past the buffer.
    pub fn many(_: *App, ctx: *http.Context) !http.Json([]const Todo) {
        const list = try ctx.allocator().alloc(Todo, 2000);
        for (list, 0..) |*t, i| t.* = .{ .id = i, .title = "a todo of a long list" };
        return .{ .value = list };
    }
    pub fn one(_: *App, _: *http.Context) !http.Json(Todo) {
        return .{ .value = .{ .id = 7, .title = "Buy milk" } };
    }
    /// A line that `flush` sends at once; the next one once the gate opens.
    pub fn live(self: *App, ctx: *http.Context) !void {
        self.liveStream(ctx) catch |err| {
            self.live_error = err;
            return err;
        };
    }
    fn liveStream(self: *App, ctx: *http.Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/plain" });
        try out.writeAll("first\n");
        try out.flush();
        self.live_stage.store(1, .release);
        try self.gate.wait(ctx.io());
        self.live_stage.store(2, .release);
        try out.writeAll("second\n");
        try out.finish();
        self.live_stage.store(3, .release);
    }
    pub fn download(self: *App, ctx: *http.Context) !void {
        try ctx.response.file(self.file_path, .{ .download_as = "data.bin" });
    }
    /// 20 KiB, so that the first 16 go out, then an error.
    pub fn broken(_: *App, ctx: *http.Context) !void {
        var out = try ctx.response.stream(.{ .content_type = "text/csv" });
        try out.writeAll(&@as([20 << 10]u8, @splat('x')));
        return error.ExportFailed;
    }
    /// Writes until a write fails, 1 GiB at most.
    pub fn flood(self: *App, ctx: *http.Context) !void {
        defer _ = self.flood_done.fetchAdd(1, .release);
        var out = try ctx.response.stream(.{ .content_type = "application/octet-stream" });
        for (0..16 << 10) |_| {
            out.writeAll(&piece) catch |err| {
                self.failed_ns = nowNs(ctx.io());
                self.flood_error = err;
                return err;
            };
            self.last_ok_ns = nowNs(ctx.io());
        }
        try out.finish();
    }
};

fn nowNs(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

/// A server of `App` on `http.native`, on a free port of loopback. It
/// stays where `start` put it.
const Fixture = struct {
    app: App,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io, timeouts: http.native.Timeouts) !void {
        f.app = .{};
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0, .timeouts = timeouts });
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

/// The 2 000 todos of `many`, in order.
fn expectTodos(a: std.mem.Allocator, body: []const u8) !void {
    const list = try std.json.parseFromSliceLeaky([]const Todo, a, body, .{});
    try testing.expectEqual(2000, list.len);
    for (list, 0..) |t, i| try testing.expectEqual(i, t.id);
}

/// A response that ended before its end: the connection closed (or
/// reset) in its middle.
fn expectCut(result: raw.Error!raw.Response) !void {
    const res = result catch |err| switch (err) {
        error.EndOfStream, error.ConnectionResetByPeer => return,
        else => |e| return e,
    };
    std.debug.print("a whole response came instead of a cut one: {d}, {d} bytes\n", .{ res.status, res.body.len });
    return error.TestResponseNotCut;
}

test "a body larger than the buffer goes chunked on 1.1 and until close on 1.0" {
    try runtime.forEachRuntime(gpa, largeBodies);
}

fn largeBodies(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a body larger than the buffer");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // HTTP/1.1: chunked, and the connection stays for the next request.
    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/todos") ++ get("/todos/one"));
    const many = try c.readResponse(io, a, .{});
    try testing.expectEqual(200, many.status);
    try testing.expectEqualStrings("application/json", many.header("content-type").?);
    try testing.expectEqualStrings("chunked", many.header("transfer-encoding").?);
    try testing.expectEqual(null, many.header("content-length"));
    try testing.expectEqual(null, many.header("connection"));
    try expectTodos(a, many.body);
    const one = try c.readResponse(io, a, .{});
    try testing.expectEqualStrings("27", one.header("content-length").?);
    try testing.expectEqualStrings("{\"id\":7,\"title\":\"Buy milk\"}", one.body);

    // HTTP/1.0 gets no chunked: the body ends with the connection, even
    // when the client asked to keep it.
    var old = try f.connect(io);
    defer old.close(io);
    try old.send(io, "GET /todos HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    const until_close = try old.readResponse(io, a, .{});
    try testing.expectEqual(200, until_close.status);
    try testing.expectEqual(null, until_close.header("transfer-encoding"));
    try testing.expectEqual(null, until_close.header("content-length"));
    try testing.expectEqualStrings("close", until_close.header("connection").?);
    try expectTodos(a, until_close.body);
    // Within the buffer: its length, and the connection kept.
    var kept = try f.connect(io);
    defer kept.close(io);
    try kept.send(io, "GET /todos/one HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    const small = try kept.readResponse(io, a, .{});
    try testing.expectEqualStrings("27", small.header("content-length").?);
    try testing.expectEqualStrings("keep-alive", small.header("connection").?);
}

test "a stream over the network: flush sends at once, finish ends it" {
    try runtime.forEachRuntime(gpa, liveStream);
}

fn liveStream(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a stream over the network");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/live"));
    // The head and the first line come while the handler waits.
    try testing.expect(try c.readUntil(io, "first\n", .fromSeconds(5)));
    try testing.expect(std.mem.find(u8, c.kept(), "Transfer-Encoding: chunked\r\n") != null);
    f.app.gate.set(io);
    const opened = Io.Clock.awake.now(io);
    const res = c.readResponse(io, a, .{}) catch |err| {
        // Where the handler stopped, what the client holds, and whether the
        // rest comes late or never.
        std.debug.print("live: {t} after {d} ms; the handler at stage {d}, error {?}; the client holds {d} bytes: {s}\n", .{
            err,          e2e.sinceMs(io, opened), f.app.live_stage.load(.acquire), f.app.live_error,
            c.kept().len, c.kept(),
        });
        const late = c.waitData(io, .fromSeconds(10)) catch |wait_err| {
            std.debug.print("live: then {t} after {d} ms; the handler at stage {d}\n", .{ wait_err, e2e.sinceMs(io, opened), f.app.live_stage.load(.acquire) });
            return err;
        };
        std.debug.print("live: then {s} after {d} ms; the handler at stage {d}; the client holds {d} bytes: {s}\n", .{
            if (late) "bytes" else "nothing", e2e.sinceMs(io, opened), f.app.live_stage.load(.acquire), c.kept().len, c.kept(),
        });
        return err;
    };
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("text/plain", res.header("content-type").?);
    try testing.expectEqualStrings("first\nsecond\n", res.body);
    // The last chunk ended it: the connection serves the next request.
    try c.send(io, get("/todos/one"));
    try testing.expectEqual(200, (try c.readResponse(io, a, .{})).status);
}

test "a file over the network, and HEAD of it" {
    try runtime.forEachRuntime(gpa, fileOverNetwork);
}

fn fileOverNetwork(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a file over the network");
    defer dog.stop(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [100_000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7 +% i / 251);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.bin", .data = &data });
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    f.app.file_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/data.bin", .{tmp.sub_path});

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/file") ++ "HEAD /file HTTP/1.1\r\nHost: test\r\n\r\n");
    const res = try c.readResponse(io, a, .{});
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("application/octet-stream", res.header("content-type").?);
    try testing.expectEqualStrings("100000", res.header("content-length").?);
    try testing.expectEqualStrings("attachment; filename=\"data.bin\"; filename*=UTF-8''data.bin", res.header("content-disposition").?);
    try testing.expectEqualSlices(u8, &data, res.body);
    const head = try c.readResponse(io, a, .{ .head_request = true });
    try testing.expectEqual(200, head.status);
    try testing.expectEqualStrings("100000", head.header("content-length").?);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
}

test "an error after commit cuts the response: no last chunk, the connection closes" {
    try runtime.forEachRuntime(gpa, cutAfterCommit);
}

fn cutAfterCommit(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "an error after commit");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{});
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/broken"));
    // The head went out with the first 16 KiB...
    try testing.expect(try c.readUntil(io, "\r\n\r\n", .fromSeconds(5)));
    try testing.expect(std.mem.startsWith(u8, c.kept(), "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.find(u8, c.kept(), "Transfer-Encoding: chunked\r\n") != null);
    // ...and the response never ends: the connection closes in its middle.
    try expectCut(c.readResponse(io, arena.allocator(), .{}));
    try e2e.waitIdle(io, &f.server);
}

test "a slow reader is cut at the write timeout" {
    try runtime.forEachRuntime(gpa, slowReader);
}

fn slowReader(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "a slow reader");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .write = .fromMilliseconds(300) });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var c = try f.connect(io);
    defer c.close(io);
    try c.send(io, get("/flood"));
    // The client reads nothing: once the buffers of the sockets are full,
    // a write sends nothing for 300 ms, and the stream fails.
    try e2e.waitCount(io, &f.app.flood_done, 1, 20_000);
    const failure = f.app.flood_error orelse {
        std.debug.print("1 GiB went out to a client that reads nothing (zio x{d})\n", .{runtime.executors});
        return error.TestStreamNotCut;
    };
    try testing.expectEqual(error.WriteFailed, failure);
    try e2e.expectWithin("the write that failed", @divTrunc(f.app.failed_ns - f.app.last_ok_ns, std.time.ns_per_ms), 300, 2000);
    // What came is the head and a part of the body, without its end.
    try expectCut(c.readResponse(io, arena.allocator(), .{ .timeout = .fromSeconds(10) }));
    try e2e.waitIdle(io, &f.server);
}
