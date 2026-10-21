//! zefir-http under load on `http.native` over loopback TCP, on zio with
//! one executor and with four: hundreds of clients kept alive, static
//! files and SSE at once, the limit of connections, and the full versions
//! of the module's stress tests (review focus 2 and 3): the slots of
//! requests come back after 10 000 requests of mixed outcomes, the slots
//! of streams after 1 000 streams of each way of ending, and 10 000
//! requests that end at their deadline get one outcome each. Each scenario
//! has a watchdog that ends the run (exit code 4) when it hangs.

const std = @import("std");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");
const e2e = @import("native.zig");

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;
const get = e2e.get;

/// What the tasks of a scenario got wrong: counted, the first five
/// printed.
pub const Failures = struct {
    count: std.atomic.Value(u32) = .init(0),

    pub fn add(f: *Failures, what: []const u8, err: anyerror) void {
        if (f.count.fetchAdd(1, .monotonic) < 5) std.debug.print("{s}: {t} (zio x{d})\n", .{ what, err, runtime.executors });
    }

    pub fn expectNone(f: *const Failures) !void {
        try testing.expectEqual(0, f.count.load(.monotonic));
    }
};

/// A connection that a worker keeps alive, opened again when the server
/// ends it. The strings of a response live until the next request.
pub const Conn = struct {
    port: u16,
    client: ?raw.Client = null,
    arena: std.heap.ArenaAllocator,

    pub fn init(port: u16) Conn {
        return .{ .port = port, .arena = .init(gpa) };
    }

    pub fn deinit(c: *Conn, io: Io) void {
        c.drop(io);
        c.arena.deinit();
    }

    /// Sends `bytes` and reads the response.
    pub fn request(c: *Conn, io: Io, bytes: []const u8) !raw.Response {
        _ = c.arena.reset(.retain_capacity);
        if (c.client == null) c.client = try raw.Client.connectSized(io, gpa, c.port, 64 << 10);
        errdefer c.drop(io);
        const client = &c.client.?;
        try client.send(io, bytes);
        const res = try client.readResponse(io, c.arena.allocator(), .{ .timeout = .fromSeconds(30) });
        if (res.header("connection")) |value| {
            if (std.ascii.eqlIgnoreCase(value, "close")) c.drop(io);
        }
        return res;
    }

    pub fn drop(c: *Conn, io: Io) void {
        if (c.client) |*client| client.close(io);
        c.client = null;
    }
};

/// Handlers at work now, and the most at once.
const Busy = struct {
    now: std.atomic.Value(u32) = .init(0),
    most: std.atomic.Value(u32) = .init(0),

    fn enter(b: *Busy) void {
        const n = b.now.fetchAdd(1, .acq_rel) + 1;
        var most = b.most.load(.monotonic);
        while (n > most) most = b.most.cmpxchgWeak(most, n, .monotonic, .monotonic) orelse break;
    }

    fn leave(b: *Busy) void {
        _ = b.now.fetchSub(1, .acq_rel);
    }
};

const Todo = struct { id: u64, title: []const u8 };

/// The application of the request scenarios. Its servers turn the strict
/// error check off: `fail` answers 500 with an error that no error
/// handler maps.
const App = struct {
    busy: Busy = .{},
    /// Requests that entered `gated`.
    entered: std.atomic.Value(u32) = .init(0),
    gate: Io.Event = .unset,

    pub const http_routes = http.routes(.{ .methods = .{
        .todo = http.get("/todos/{id}", .{}),
        .held = http.get("/held", .{}),
        .ok = http.get("/ok", .{}),
        .fail = http.get("/fail", .{}),
        .short = http.get("/short", .{ .timeout = std.Io.Duration.fromMilliseconds(5) }),
        .stay = http.get("/stay", .{}),
        .edge = http.get("/edge/{n}", .{ .timeout = std.Io.Duration.fromMilliseconds(5) }),
        .gated = http.get("/gated", .{}),
    } });

    pub fn todo(_: *App, ctx: *http.Context) !http.Json(Todo) {
        const path = try ctx.path(struct { id: u64 });
        return .{ .value = .{ .id = path.id, .title = "todo" } };
    }
    /// A millisecond of work, counted in `busy`.
    pub fn held(self: *App, ctx: *http.Context) !void {
        self.busy.enter();
        defer self.busy.leave();
        try ctx.io().sleep(.fromMilliseconds(1), .awake);
        try ctx.response.text("held");
    }
    pub fn ok(_: *App, _: *http.Context) !void {}
    pub fn fail(_: *App, _: *http.Context) !void {
        return error.TodoNotFound;
    }
    /// A second of work, past its deadline of 5 ms: 504. The deadline
    /// cancels the work, so a second costs nothing, and a runner that
    /// leaves the connection's task waiting under load cannot let the
    /// work end first.
    pub fn short(_: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromSeconds(1), .awake);
    }
    /// Five seconds of work: its client leaves first.
    pub fn stay(_: *App, ctx: *http.Context) !void {
        try ctx.io().sleep(.fromSeconds(5), .awake);
    }
    /// Ends 4, 5 or 6 ms in, at its deadline of 5 ms.
    pub fn edge(_: *App, ctx: *http.Context) !void {
        const path = try ctx.path(struct { n: u32 });
        try ctx.io().sleep(.fromMilliseconds(4 + path.n % 3), .awake);
        try ctx.response.text("done");
    }
    pub fn gated(self: *App, ctx: *http.Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try self.gate.wait(ctx.io());
    }
};

/// The server's middleware in the request scenarios: it does what the
/// request's `x-do` says (`handle`: 202 and `.handled`; `fail`: its run
/// fails; `finish-fail`: its onFinish fails), and checks that each request
/// of `/edge/{n}` ends once, with the handler's 200 or a 504.
const Ledger = struct {
    edge_finished: std.atomic.Value(u32) = .init(0),
    edge_wrong: std.atomic.Value(u32) = .init(0),

    pub fn run(_: *Ledger, ctx: *http.Context) !http.MiddlewareResult {
        const what = ctx.request.header("x-do") orelse return .next;
        if (std.mem.eql(u8, what, "handle")) {
            _ = ctx.response.status(202);
            return .handled;
        }
        if (std.mem.eql(u8, what, "fail")) return error.Refused;
        return .next;
    }

    pub fn onFinish(self: *Ledger, ctx: *http.Context, outcome: http.Outcome) !void {
        if (std.mem.startsWith(u8, ctx.request.path, "/edge/")) {
            _ = self.edge_finished.fetchAdd(1, .monotonic);
            const answered = !outcome.aborted and outcome.status == 200 and outcome.err == null;
            const timed_out = if (outcome.err) |err| err == error.RequestTimeout else false;
            if (!answered and !(timed_out and !outcome.aborted and outcome.status == 504)) _ = self.edge_wrong.fetchAdd(1, .monotonic);
        }
        const what = ctx.request.header("x-do") orelse return;
        if (std.mem.eql(u8, what, "finish-fail")) return error.Broken;
    }
};

/// A server of `App` on `http.native`, on a free port of loopback. It
/// stays where `start` put it.
const Fixture = struct {
    app: App,
    ledger: Ledger,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io, limits: http.native.Limits, max_in_flight: u32) !void {
        f.app = .{};
        f.ledger = .{};
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0, .limits = limits });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{
            .controllers = .{&f.app},
            .middleware = .{&f.ledger},
            .strict_errors = false,
        }, .{
            .listen = .{ .backend = f.native.backend() },
            .max_in_flight = max_in_flight,
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.native.deinit();
    }

    fn port(f: *const Fixture) u16 {
        return f.native.port();
    }
};

// Keep-alive under load.

const load_clients = 200;
const load_requests = 500;

test "keep-alive under load: 200 clients × 500 requests, every response correct" {
    try runtime.forEachRuntime(gpa, keepAliveUnderLoad);
}

fn keepAliveUnderLoad(io: Io) !void {
    var dog = try e2e.Watchdog.startFor(io, "keep-alive under load", 180);
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{}, 10_000);
    defer f.deinit(io);

    var failures: Failures = .{};
    var clients: Io.Group = .init;
    defer clients.cancel(io);
    for (0..load_clients) |i| try clients.concurrent(io, loadClient, .{ io, f.port(), i, &failures });
    try clients.await(io);
    try failures.expectNone();
    try e2e.waitIdle(io, &f.server);
}

fn loadClient(io: Io, port: u16, index: usize, failures: *Failures) void {
    loadRequests(io, port, index) catch |err| failures.add("a client kept alive", err);
}

/// `load_requests` requests one after another on one connection, each for
/// a todo of its own.
fn loadRequests(io: Io, port: u16, index: usize) !void {
    var c = try raw.Client.connectSized(io, gpa, port, 16 << 10);
    defer c.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var request: [64]u8 = undefined;
    var body: [64]u8 = undefined;
    for (0..load_requests) |i| {
        _ = arena.reset(.retain_capacity);
        const id = index * load_requests + i;
        try c.send(io, try std.fmt.bufPrint(&request, "GET /todos/{d} HTTP/1.1\r\nHost: test\r\n\r\n", .{id}));
        const res = try c.readResponse(io, arena.allocator(), .{ .timeout = .fromSeconds(30) });
        if (res.status != 200) return error.TestUnexpectedStatus;
        if (res.header("connection") != null) return error.TestNotKeptAlive;
        const want = try std.fmt.bufPrint(&body, "{{\"id\":{d},\"title\":\"todo\"}}", .{id});
        if (!std.mem.eql(u8, res.body, want)) return error.TestWrongBody;
    }
}

// The limit of connections under load.

test "max_connections under load: 64 clients through 8 connections, all served" {
    try runtime.forEachRuntime(gpa, maxConnectionsUnderLoad);
}

fn maxConnectionsUnderLoad(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "max_connections under load");
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{ .max_connections = 8 }, 10_000);
    defer f.deinit(io);

    // 64 clients connect at once, each for 20 requests of a millisecond;
    // those over the limit wait in the kernel's queue until one closes.
    var failures: Failures = .{};
    var clients: Io.Group = .init;
    defer clients.cancel(io);
    for (0..64) |_| try clients.concurrent(io, heldClient, .{ io, f.port(), &failures });
    try clients.await(io);
    try failures.expectNone();
    const most = f.app.busy.most.load(.monotonic);
    if (most > 8) {
        std.debug.print("{d} requests at work at once through 8 connections (zio x{d})\n", .{ most, runtime.executors });
        return error.TestOverTheLimit;
    }
    try e2e.waitIdle(io, &f.server);
}

fn heldClient(io: Io, port: u16, failures: *Failures) void {
    heldRequests(io, port) catch |err| failures.add("a client of the limit", err);
}

fn heldRequests(io: Io, port: u16) !void {
    var c = try raw.Client.connectSized(io, gpa, port, 16 << 10);
    defer c.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..20) |_| {
        _ = arena.reset(.retain_capacity);
        try c.send(io, get("/held"));
        const res = try c.readResponse(io, arena.allocator(), .{ .timeout = .fromSeconds(30) });
        if (res.status != 200 or !std.mem.eql(u8, res.body, "held")) return error.TestUnexpectedResponse;
    }
}

// Review focus 2: the slots of requests come back after every outcome.

/// A request of review focus 2 and the status it gets when it has a
/// place; `leave`: its client leaves before the response.
const Mixed = struct { request: []const u8, status: u16, leave: bool = false };

const mixed = [_]Mixed{
    .{ .request = get("/ok"), .status = 204 },
    .{ .request = get("/fail"), .status = 500 },
    .{ .request = get("/short"), .status = 504 },
    .{ .request = get("/stay"), .status = 0, .leave = true },
    .{ .request = get("/nothing"), .status = 404 },
    .{ .request = "PUT /ok HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\n\r\n", .status = 405 },
    .{ .request = "GET /ok HTTP/1.1\r\nHost: test\r\nX-Do: handle\r\n\r\n", .status = 202 },
    .{ .request = "GET /ok HTTP/1.1\r\nHost: test\r\nX-Do: fail\r\n\r\n", .status = 500 },
    .{ .request = "GET /ok HTTP/1.1\r\nHost: test\r\nX-Do: finish-fail\r\n\r\n", .status = 204 },
};

test "in-flight slots come back after 10 000 mixed outcomes" {
    try runtime.forEachRuntime(gpa, mixedOutcomes);
}

fn mixedOutcomes(io: Io) !void {
    var dog = try e2e.Watchdog.startFor(io, "in-flight slots after 10 000 mixed outcomes", 120);
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{}, 4);
    defer f.deinit(io);

    // 10 000 requests from 16 workers on four places, so that many get
    // 503: success, a failing handler, a deadline, a client that leaves,
    // 404, 405, `.handled`, a failing run and a failing onFinish.
    var taken: std.atomic.Value(u32) = .init(0);
    var failures: Failures = .{};
    var workers: Io.Group = .init;
    defer workers.cancel(io);
    for (0..16) |_| try workers.concurrent(io, mixedWorker, .{ io, f.port(), &taken, 10_000, &failures });
    try workers.await(io);
    try failures.expectNone();
    try e2e.waitIdle(io, &f.server);

    // All four places are free: four requests at once all enter.
    var held: [4]raw.Client = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |*c| c.close(io);
    for (&held) |*c| {
        c.* = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
        opened += 1;
        try c.send(io, get("/gated"));
    }
    try e2e.waitCount(io, &f.app.entered, 4, 5000);
    f.app.gate.set(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (&held) |*c| try testing.expectEqual(204, (try c.readResponse(io, arena.allocator(), .{})).status);
    try e2e.waitIdle(io, &f.server);
}

/// Requests of the outcomes in turn, until `taken` reaches `total`.
fn mixedWorker(io: Io, port: u16, taken: *std.atomic.Value(u32), total: u32, failures: *Failures) void {
    var conn: Conn = .init(port);
    defer conn.deinit(io);
    while (true) {
        const n = taken.fetchAdd(1, .monotonic);
        if (n >= total) return;
        const outcome = mixed[n % mixed.len];
        mixedOne(io, &conn, outcome) catch |err| {
            failures.add(outcome.request[0 .. std.mem.findScalar(u8, outcome.request, '\r') orelse outcome.request.len], err);
        };
    }
}

fn mixedOne(io: Io, conn: *Conn, outcome: Mixed) !void {
    if (outcome.leave) {
        // On a connection of its own: the client sends its request and
        // leaves a millisecond later.
        var c = try raw.Client.connectSized(io, gpa, conn.port, 16 << 10);
        defer c.close(io);
        try c.send(io, outcome.request);
        try io.sleep(.fromMilliseconds(1), .awake);
        return;
    }
    const res = try conn.request(io, outcome.request);
    if (res.status != outcome.status and res.status != 503) {
        std.debug.print("{d} instead of {d}\n", .{ res.status, outcome.status });
        return error.TestUnexpectedStatus;
    }
}

// Review focus 3: a handler that ends at its deadline.

test "10 000 requests that end at their deadline get one outcome each" {
    try runtime.forEachRuntime(gpa, edgesAtDeadline);
}

fn edgesAtDeadline(io: Io) !void {
    var dog = try e2e.Watchdog.startFor(io, "10 000 requests at their deadline", 120);
    defer dog.stop(io);
    var f: Fixture = undefined;
    try f.start(io, .{}, 10_000);
    defer f.deinit(io);

    // 16 workers; each handler ends 4, 5 or 6 ms in, at a deadline of
    // 5 ms. Each request gets the handler's 200 or 504, once, and reaches
    // onFinish once.
    var taken: std.atomic.Value(u32) = .init(0);
    var counts: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) };
    var failures: Failures = .{};
    var workers: Io.Group = .init;
    defer workers.cancel(io);
    for (0..16) |_| try workers.concurrent(io, edgeWorker, .{ io, f.port(), &taken, 10_000, &counts, &failures });
    try workers.await(io);
    try failures.expectNone();
    try e2e.waitIdle(io, &f.server);
    try testing.expectEqual(10_000, counts[0].load(.monotonic) + counts[1].load(.monotonic));
    try testing.expectEqual(10_000, f.ledger.edge_finished.load(.monotonic));
    try testing.expectEqual(0, f.ledger.edge_wrong.load(.monotonic));
}

fn edgeWorker(io: Io, port: u16, taken: *std.atomic.Value(u32), total: u32, counts: *[2]std.atomic.Value(u32), failures: *Failures) void {
    var conn: Conn = .init(port);
    defer conn.deinit(io);
    while (true) {
        const n = taken.fetchAdd(1, .monotonic);
        if (n >= total) return;
        edgeOne(io, &conn, n, counts) catch |err| failures.add("GET /edge/{n}", err);
    }
}

fn edgeOne(io: Io, conn: *Conn, n: u32, counts: *[2]std.atomic.Value(u32)) !void {
    var request: [64]u8 = undefined;
    const res = try conn.request(io, try std.fmt.bufPrint(&request, "GET /edge/{d} HTTP/1.1\r\nHost: test\r\n\r\n", .{n}));
    if (res.status == 200 and std.mem.eql(u8, res.body, "done")) {
        _ = counts[0].fetchAdd(1, .monotonic);
    } else if (res.status == 504 and std.mem.eql(u8, res.header("content-type") orelse "", "application/problem+json")) {
        _ = counts[1].fetchAdd(1, .monotonic);
    } else {
        std.debug.print("/edge/{d}: {d} {s}\n", .{ n, res.status, res.body });
        return error.TestUnexpectedResponse;
    }
}

// Static files and SSE at once.

/// Streams of the site: every client on the key "all".
const SiteApp = struct {
    live: *http.sse.Manager,
    subscribed: std.atomic.Value(u32) = .init(0),

    pub const http_routes = http.routes(.{ .methods = .{
        .events = http.sse.get("/events", .{}),
    } });

    pub fn events(self: *SiteApp, ctx: *http.sse.Context) !void {
        _ = try self.live.subscribe(ctx, "all");
        _ = self.subscribed.fetchAdd(1, .release);
    }
};

/// The files of the site, in a directory of its own.
const Site = struct {
    tmp: testing.TmpDir,
    /// The root, relative to the working directory.
    root: []const u8,
    large: []u8,

    fn create(a: std.mem.Allocator) !Site {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const large = try a.alloc(u8, 256 << 10);
        for (large, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 251);
        try tmp.dir.createDirPath(testing.io, "public");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "public/a.txt", .data = "alpha" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "public/large.bin", .data = large });
        return .{ .tmp = tmp, .root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/public", .{tmp.sub_path}), .large = large };
    }
};

const SiteFixture = struct {
    live: http.sse.Manager,
    app: SiteApp,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *SiteFixture, io: Io, root: []const u8) !void {
        f.live = .init(gpa, .{});
        errdefer f.live.deinit(io);
        f.app = .{ .live = &f.live };
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{
            .controllers = .{&f.app},
        }, .{
            .listen = .{ .backend = f.native.backend() },
            .static = &.{http.static("/", .{ .root = root })},
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *SiteFixture, io: Io) void {
        f.server.deinit(io);
        f.live.deinit(io);
        f.native.deinit();
    }
};

const site_events = 200;

test "static files and SSE over the network at once" {
    try runtime.forEachRuntime(gpa, staticAndStreams);
}

fn staticAndStreams(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "static files and SSE at once");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var site = try Site.create(arena.allocator());
    defer site.tmp.cleanup();
    var f: SiteFixture = undefined;
    try f.start(io, site.root);
    defer f.deinit(io);

    // Eight clients read 200 events each while eight others fetch files
    // on keep-alive: whole, 304 and a range of a large one.
    var failures: Failures = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..8) |_| try group.concurrent(io, subscriber, .{ io, f.native.port(), &failures });
    try group.concurrent(io, publisher, .{ io, &f, &failures });
    for (0..8) |_| try group.concurrent(io, fileClient, .{ io, f.native.port(), site.large, &failures });
    try group.await(io);
    try failures.expectNone();
    try waitNoStreams(io, &f.server);
    // A response is out before the server lets go of its place.
    try e2e.waitIdle(io, &f.server);
}

fn subscriber(io: Io, port: u16, failures: *Failures) void {
    readEvents(io, port) catch |err| failures.add("a subscriber", err);
}

/// Every event, in the order it was published; then the client leaves.
fn readEvents(io: Io, port: u16) !void {
    var c = try raw.Client.connect(io, gpa, port);
    defer c.close(io);
    try c.send(io, get("/events"));
    if (!try c.readUntil(io, "id: 199\ndata: 199\n\n", .fromSeconds(30))) return error.TestEventsMissing;
    var at: usize = 0;
    var event: [32]u8 = undefined;
    for (0..site_events) |i| {
        const text = try std.fmt.bufPrint(&event, "id: {d}\ndata: {d}\n\n", .{ i, i });
        at = (std.mem.findPos(u8, c.kept(), at, text) orelse return error.TestEventOutOfOrder) + text.len;
    }
}

fn publisher(io: Io, f: *SiteFixture, failures: *Failures) void {
    publishEvents(io, f) catch |err| failures.add("the publisher", err);
}

/// Once every subscriber is in: 200 events, a pause every eight so that
/// no queue fills.
fn publishEvents(io: Io, f: *SiteFixture) !void {
    try e2e.waitCount(io, &f.app.subscribed, 8, 5000);
    var id: [16]u8 = undefined;
    for (0..site_events) |i| {
        try f.live.publish(.root, io, "all", .{ .id = try std.fmt.bufPrint(&id, "{d}", .{i}), .data = i });
        if (i % 8 == 7) try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn fileClient(io: Io, port: u16, large: []const u8, failures: *Failures) void {
    fetchFiles(io, port, large) catch |err| failures.add("a client of the files", err);
}

/// 25 rounds on one connection: a file, its 304, a large file and a range
/// of it.
fn fetchFiles(io: Io, port: u16, large: []const u8) !void {
    var c = try raw.Client.connect(io, gpa, port);
    defer c.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..25) |_| {
        _ = arena.reset(.retain_capacity);
        try c.send(io, get("/a.txt"));
        const small = try c.readResponse(io, a, .{ .timeout = .fromSeconds(30) });
        if (small.status != 200 or !std.mem.eql(u8, small.body, "alpha")) return error.TestWrongFile;
        const etag = small.header("etag") orelse return error.TestNoEtag;
        try c.send(io, try std.fmt.allocPrint(a, "GET /a.txt HTTP/1.1\r\nHost: test\r\nIf-None-Match: {s}\r\n\r\n", .{etag}));
        if ((try c.readResponse(io, a, .{ .timeout = .fromSeconds(30) })).status != 304) return error.TestNot304;
        try c.send(io, get("/large.bin"));
        const whole = try c.readResponse(io, a, .{ .timeout = .fromSeconds(30) });
        if (whole.status != 200 or !std.mem.eql(u8, whole.body, large)) return error.TestWrongFile;
        try c.send(io, "GET /large.bin HTTP/1.1\r\nHost: test\r\nRange: bytes=1000-1999\r\n\r\n");
        const part = try c.readResponse(io, a, .{ .timeout = .fromSeconds(30) });
        if (part.status != 206 or !std.mem.eql(u8, part.body, large[1000..2000])) return error.TestWrongRange;
    }
}

/// Waits until the server has no stream open, five seconds at most.
fn waitNoStreams(io: Io, server: *const http.Server) !void {
    const start = Io.Clock.awake.now(io);
    while (http.testing.openStreams(server) != 0) {
        if (e2e.sinceMs(io, start) > 5000) return error.TestStreamsStillOpen;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

// Review focus 2 for streams: their slots come back after every way a
// stream ends.

const stream_workers = 4;
/// Rounds of each worker; a round ends a stream of each way.
const stream_rounds = 250;

/// The application of the stream scenario: each stream on the key
/// `{worker}-{cause}`; `failing` fails after its subscribe.
const StreamApp = struct {
    live: *http.sse.Manager,
    /// By worker: streams subscribed, and streams ended (their on_close).
    opened: [stream_workers]std.atomic.Value(u32) = @splat(.init(0)),
    closed: [stream_workers]std.atomic.Value(u32) = @splat(.init(0)),

    pub const http_routes = http.routes(.{ .methods = .{
        .events = http.sse.get("/events/{worker}/{cause}", .{ .on_close = .eventsClosed }),
        .failing = http.sse.get("/failing/{worker}/{cause}", .{ .on_close = .eventsClosed }),
    } });

    const Key = struct { worker: u8, cause: []const u8 };

    pub fn events(self: *StreamApp, ctx: *http.sse.Context) !void {
        try self.open(ctx);
    }

    pub fn failing(self: *StreamApp, ctx: *http.sse.Context) !void {
        try self.open(ctx);
        return error.AfterSubscribe;
    }

    fn open(self: *StreamApp, ctx: *http.sse.Context) !void {
        const key = try ctx.path(Key);
        if (key.worker >= stream_workers) return error.NoSuchWorker;
        _ = try self.live.subscribe(ctx, try std.fmt.allocPrint(ctx.allocator(), "{d}-{s}", .{ key.worker, key.cause }));
        _ = self.opened[key.worker].fetchAdd(1, .release);
    }

    pub fn eventsClosed(self: *StreamApp, ctx: *http.sse.Context) void {
        const key = ctx.path(Key) catch return;
        _ = self.closed[key.worker].fetchAdd(1, .release);
    }

    fn closedInAll(self: *const StreamApp) u32 {
        var n: u32 = 0;
        for (&self.closed) |*c| n += c.load(.acquire);
        return n;
    }
};

const StreamFixture = struct {
    live: http.sse.Manager,
    app: StreamApp,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *StreamFixture, io: Io) !void {
        // A queue of two events, so that a burst of three overflows it.
        f.live = .init(gpa, .{ .queue = .{ .max_events = 2 } });
        errdefer f.live.deinit(io);
        f.app = .{ .live = &f.live };
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{
            .controllers = .{&f.app},
            .strict_errors = false,
        }, .{
            .listen = .{ .backend = f.native.backend() },
            .max_streams = 2 * stream_workers,
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *StreamFixture, io: Io) void {
        f.server.deinit(io);
        f.live.deinit(io);
        f.native.deinit();
    }

    fn port(f: *const StreamFixture) u16 {
        return f.native.port();
    }
};

test "stream slots come back after 1 000 streams ended by each cause" {
    try runtime.forEachRuntime(gpa, streamSlots);
}

fn streamSlots(io: Io) !void {
    var dog = try e2e.Watchdog.startFor(io, "stream slots after 1 000 streams of each end", 120);
    defer dog.stop(io);
    var f: StreamFixture = undefined;
    try f.start(io);
    defer f.deinit(io);

    // Four workers, 250 rounds each: a stream whose client leaves, one
    // that close(key) ends (its connection then serves the next of its
    // kind), one whose queue overflows, one whose handler fails after
    // subscribe. A worker waits for the end of each stream before the
    // next, so that it holds two places at most: the server has eight,
    // and no stream gets 503.
    var failures: Failures = .{};
    var workers: Io.Group = .init;
    defer workers.cancel(io);
    for (0..stream_workers) |w| try workers.concurrent(io, streamWorker, .{ io, &f, @as(u8, @intCast(w)), &failures });
    try workers.await(io);
    try failures.expectNone();
    try waitNoStreams(io, &f.server);
    try e2e.waitIdle(io, &f.server);
    try testing.expectEqual(4 * stream_workers * stream_rounds, f.app.closedInAll());

    // Every place is free: eight new streams open, a ninth gets 503.
    var held: [2 * stream_workers]raw.Client = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |*c| c.close(io);
    const before = f.app.opened[0].load(.acquire);
    for (&held) |*c| {
        c.* = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
        opened += 1;
        try c.send(io, get("/events/0/held"));
    }
    try e2e.waitCount(io, &f.app.opened[0], before + @as(u32, held.len), 5000);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    {
        var over = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
        defer over.close(io);
        try over.send(io, get("/events/0/over"));
        try testing.expectEqual(503, (try over.readResponse(io, arena.allocator(), .{})).status);
    }

    // The stop ends them, each with its last chunk.
    try f.server.shutdown(io);
    for (&held) |*c| {
        const res = try c.readResponse(io, arena.allocator(), .{});
        try testing.expectEqual(200, res.status);
        try testing.expectEqualStrings("", res.body);
    }
    try testing.expectEqual(4 * stream_workers * stream_rounds + held.len, f.app.closedInAll());
    try testing.expectEqual(0, http.testing.openStreams(&f.server));
}

fn streamWorker(io: Io, f: *StreamFixture, w: u8, failures: *Failures) void {
    streamRounds(io, f, w) catch |err| failures.add("a stream worker", err);
}

fn streamRounds(io: Io, f: *StreamFixture, w: u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var keep = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
    defer keep.close(io);
    var buffer: [64]u8 = undefined;
    // This worker's streams so far: subscribed, and ended.
    var subscribed: u32 = 0;
    var ended: u32 = 0;
    for (0..stream_rounds) |_| {
        _ = arena.reset(.retain_capacity);
        // The client leaves once its stream is open.
        {
            var c = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
            defer c.close(io);
            try c.send(io, try std.fmt.bufPrint(&buffer, "GET /events/{d}/left HTTP/1.1\r\nHost: test\r\n\r\n", .{w}));
            subscribed += 1;
            try e2e.waitCount(io, &f.app.opened[w], subscribed, 5000);
        }
        ended += 1;
        try e2e.waitCount(io, &f.app.closed[w], ended, 5000);

        // close(key): the last chunk ends the response, and the connection
        // stays for the next request.
        try keep.send(io, try std.fmt.bufPrint(&buffer, "GET /events/{d}/keep HTTP/1.1\r\nHost: test\r\n\r\n", .{w}));
        subscribed += 1;
        try e2e.waitCount(io, &f.app.opened[w], subscribed, 5000);
        f.live.close(io, try std.fmt.bufPrint(&buffer, "{d}-keep", .{w}));
        const res = try keep.readResponse(io, arena.allocator(), .{});
        if (res.status != 200 or res.body.len != 0) return error.TestNotClosedWhole;
        ended += 1;
        try e2e.waitCount(io, &f.app.closed[w], ended, 5000);

        // An overflow: bursts of events come faster than the stream sends
        // them, and its queue holds two.
        {
            var c = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
            defer c.close(io);
            try c.send(io, try std.fmt.bufPrint(&buffer, "GET /events/{d}/slow HTTP/1.1\r\nHost: test\r\n\r\n", .{w}));
            subscribed += 1;
            try e2e.waitCount(io, &f.app.opened[w], subscribed, 5000);
            const key = try std.fmt.bufPrint(&buffer, "{d}-slow", .{w});
            ended += 1;
            var published: usize = 0;
            while (f.app.closed[w].load(.acquire) < ended) : (published += 1) {
                if (published == 100_000) return error.TestNoOverflow;
                try f.live.publish(.root, io, key, .{ .data = "overflow" });
                if (published % 8 == 7) try io.sleep(.fromMilliseconds(1), .awake);
            }
        }

        // The handler fails after subscribe: the stream is cut at once.
        {
            var c = try raw.Client.connectSized(io, gpa, f.port(), 16 << 10);
            defer c.close(io);
            try c.send(io, try std.fmt.bufPrint(&buffer, "GET /failing/{d}/fail HTTP/1.1\r\nHost: test\r\n\r\n", .{w}));
            subscribed += 1;
            ended += 1;
            try e2e.waitCount(io, &f.app.closed[w], ended, 5000);
        }
    }
}
