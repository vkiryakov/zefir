//! The stop of a server under load, on `http.native` over loopback TCP,
//! on zio with one executor and with four: requests answered, requests at
//! their deadline and requests that outlive the grace, all at once when
//! the stop comes. Every request ends once, and the server stops soon
//! after `.shutdown_grace`: a second after it is the server's budget, and
//! the test gives slow runners of CI three.

const std = @import("std");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");
const e2e = @import("native.zig");
const load = @import("load.zig");

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;

const App = struct {
    pub const http_routes = http.routes(.{ .methods = .{
        .quick = http.get("/quick/{id}", .{}),
        .late = http.get("/late/{id}", .{ .timeout = std.Io.Duration.fromMilliseconds(20) }),
        .long = http.get("/long/{id}", .{}),
    } });

    const Id = struct { id: u64 };

    /// The id, at once.
    pub fn quick(_: *App, ctx: *http.Context) !void {
        const path = try ctx.path(Id);
        try ctx.response.text(try std.fmt.allocPrint(ctx.allocator(), "{d}", .{path.id}));
    }
    /// A second of work, past its deadline of 20 ms: 504.
    pub fn late(_: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromSeconds(1), .awake);
    }
    /// Ten seconds of work: the stop cancels it after the grace.
    pub fn long(_: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromSeconds(10), .awake);
    }
};

/// The server's middleware: each request that enters the chain, and each
/// that reaches onFinish, by how it ended.
const Ledger = struct {
    started: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    answered: std.atomic.Value(u32) = .init(0),
    timed_out: std.atomic.Value(u32) = .init(0),
    aborted: std.atomic.Value(u32) = .init(0),
    other: std.atomic.Value(u32) = .init(0),

    pub fn run(self: *Ledger, _: *http.Context) !http.MiddlewareResult {
        _ = self.started.fetchAdd(1, .monotonic);
        return .next;
    }

    pub fn onFinish(self: *Ledger, _: *http.Context, outcome: http.Outcome) !void {
        _ = self.finished.fetchAdd(1, .monotonic);
        const kind = if (outcome.aborted) &self.aborted else switch (outcome.status) {
            200 => &self.answered,
            504 => &self.timed_out,
            else => &self.other,
        };
        _ = kind.fetchAdd(1, .monotonic);
    }
};

const grace_ms = 300;

const Fixture = struct {
    app: App,
    ledger: Ledger,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io) !void {
        f.app = .{};
        f.ledger = .{};
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{
            .controllers = .{&f.app},
            .middleware = .{&f.ledger},
        }, .{
            .listen = .{ .backend = f.native.backend() },
            .shutdown_grace = std.Io.Duration.fromMilliseconds(grace_ms),
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.native.deinit();
    }
};

const long_clients = 8;
const loop_clients = 24;

test "deadline and stop under load: every request ends once, the server stops within shutdown_grace + 3 s" {
    try runtime.forEachRuntime(gpa, stopUnderLoad);
}

fn stopUnderLoad(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "deadline and stop under load");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io);
    defer f.deinit(io);

    // Eight requests of ten seconds, and 24 clients that send requests
    // answered at once and requests past their deadline, one after another
    // on their connections.
    var stopping: std.atomic.Value(bool) = .init(false);
    var failures: load.Failures = .{};
    var clients: Io.Group = .init;
    defer clients.cancel(io);
    for (0..long_clients) |i| try clients.concurrent(io, longClient, .{ io, f.native.port(), i, &stopping, &failures });
    for (0..loop_clients) |i| try clients.concurrent(io, loopClient, .{ io, f.native.port(), i, &stopping, &failures });
    try e2e.waitCount(io, &f.ledger.started, 1000, 30_000);

    // The stop, with all of them at work.
    stopping.store(true, .release);
    const stop = Io.Clock.awake.now(io);
    f.server.requestStop(io);
    try f.server.wait(io);
    try e2e.expectWithin("the stop under load", e2e.sinceMs(io, stop), grace_ms, grace_ms + 3000);
    try clients.await(io);
    try failures.expectNone();

    // Every request ended once: answered, at its deadline, or canceled by
    // the stop (the long ones).
    const started = f.ledger.started.load(.monotonic);
    try testing.expectEqual(started, f.ledger.finished.load(.monotonic));
    try testing.expectEqual(0, f.ledger.other.load(.monotonic));
    try testing.expectEqual(long_clients, f.ledger.aborted.load(.monotonic));
    try testing.expect(f.ledger.answered.load(.monotonic) > 0);
    try testing.expect(f.ledger.timed_out.load(.monotonic) > 0);
}

/// A request that outlives the grace: the stop cancels it, and its
/// connection ends without a response.
fn longClient(io: Io, port: u16, index: usize, stopping: *const std.atomic.Value(bool), failures: *load.Failures) void {
    longRequest(io, port, index, stopping) catch |err| failures.add("a long request", err);
}

fn longRequest(io: Io, port: u16, index: usize, stopping: *const std.atomic.Value(bool)) !void {
    var c = try raw.Client.connectSized(io, gpa, port, 16 << 10);
    defer c.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var request: [64]u8 = undefined;
    try c.send(io, try std.fmt.bufPrint(&request, "GET /long/{d} HTTP/1.1\r\nHost: test\r\n\r\n", .{index}));
    if (c.readResponse(io, arena.allocator(), .{ .timeout = .fromSeconds(30) })) |res| {
        std.debug.print("a long request got {d}\n", .{res.status});
        return error.TestResponseAfterCancel;
    } else |err| switch (err) {
        error.EndOfStream, error.ConnectionResetByPeer => if (!stopping.load(.acquire)) return error.TestEndBeforeStop,
        else => |e| return e,
    }
}

/// Requests answered at once and requests past their deadline, until the
/// stop ends the connection.
fn loopClient(io: Io, port: u16, index: usize, stopping: *const std.atomic.Value(bool), failures: *load.Failures) void {
    loopRequests(io, port, index, stopping) catch |err| failures.add("a client of the stop", err);
}

fn loopRequests(io: Io, port: u16, index: usize, stopping: *const std.atomic.Value(bool)) !void {
    var c = try raw.Client.connectSized(io, gpa, port, 16 << 10);
    defer c.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var request: [64]u8 = undefined;
    var body: [32]u8 = undefined;
    var i: usize = 0;
    while (true) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const id = index * 1_000_000 + i;
        const late = i % 3 == 2;
        const bytes = try std.fmt.bufPrint(&request, "GET /{s}/{d} HTTP/1.1\r\nHost: test\r\n\r\n", .{ if (late) "late" else "quick", id });
        c.send(io, bytes) catch |err| {
            if (stopping.load(.acquire)) return;
            return err;
        };
        const res = c.readResponse(io, arena.allocator(), .{ .timeout = .fromSeconds(30) }) catch |err| switch (err) {
            // The stop closed the connection between two requests.
            error.EndOfStream, error.ConnectionResetByPeer => if (stopping.load(.acquire)) return else return err,
            else => |e| return e,
        };
        if (late) {
            if (res.status != 504) return error.TestNot504;
        } else {
            if (res.status != 200) return error.TestUnexpectedStatus;
            if (!std.mem.eql(u8, res.body, try std.fmt.bufPrint(&body, "{d}", .{id}))) return error.TestWrongBody;
        }
        if (res.header("connection")) |value| {
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                if (!stopping.load(.acquire)) return error.TestCloseBeforeStop;
                return;
            }
        }
    }
}
