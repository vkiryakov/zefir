//! The benchmark of zefir-http: a server on `http.native` and the clients
//! that load it, in one process over loopback, on zio with one executor
//! and with four. Each client keeps its connection alive and sends its
//! requests one after another; the scenarios are plain text, JSON out,
//! JSON in and out, a static file, and a route with a chain of five
//! middleware elements, each with one connection and with 64. It prints
//! requests per second and the percentiles of the latency of a request.
//!
//! `zig build bench` in tests/http runs it, built with ReleaseFast unless
//! `-Dbench-optimize` says otherwise; the workflow `bench.yml` runs it so
//! on a GitHub-hosted Linux runner. The numbers depend on the machine, and
//! the clients share the CPU with the server: they are for comparing
//! builds and runtimes, not a promise. A panic prints its message and
//! exits with code 3 instead of aborting.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http");
const zio = @import("zio");

const Io = std.Io;
const net = Io.net;

pub const panic = std.debug.FullPanic(exitOnPanic);

/// Warnings and errors only: no debug lines of zio.
pub const std_options: std.Options = .{ .log_level = .warn };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const gpa = std.heap.smp_allocator;

const Todo = struct { id: u64, title: []const u8, done: bool };
const NewTodo = struct { title: []const u8, done: bool = false };

/// The routes of the scenarios.
const App = struct {
    pub const http_routes = http.routes(.{ .methods = .{
        .text = http.get("/text", .{}),
        .todo = http.get("/todos/{id}", .{}),
        .create = http.post("/todos", .{}),
        .chained = http.get("/chained", .{ .middleware = .{ first, second, third, Timing, http.onResponse(stamp) } }),
    } });

    pub fn text(_: *App, ctx: *http.Context) !void {
        try ctx.response.text("hello, world");
    }

    pub fn todo(_: *App, ctx: *http.Context) !http.Json(Todo) {
        const path = try ctx.path(struct { id: u64 });
        return .{ .value = .{ .id = path.id, .title = "Buy milk", .done = false } };
    }

    pub fn create(_: *App, ctx: *http.Context) !http.Json(Todo) {
        const input = try ctx.json(NewTodo);
        return .{ .status = 201, .value = .{ .id = 1, .title = input.title, .done = input.done } };
    }

    pub fn chained(_: *App, ctx: *http.Context) !void {
        try ctx.response.text("chained");
    }

    fn first(_: *http.Context) !http.MiddlewareResult {
        return .next;
    }
    fn second(_: *http.Context) !http.MiddlewareResult {
        return .next;
    }
    fn third(_: *http.Context) !http.MiddlewareResult {
        return .next;
    }
    /// The time of a request, as an access log would take it.
    const Timing = struct {
        pub fn run(ctx: *http.Context) !http.MiddlewareResult {
            std.mem.doNotOptimizeAway(ctx.now());
            return .next;
        }
        pub fn onFinish(_: *http.Context, outcome: http.Outcome) !void {
            std.mem.doNotOptimizeAway(outcome.duration);
        }
    };
    fn stamp(ctx: *http.Context) !void {
        try ctx.response.setHeader("x-chain", "5");
    }
};

const Scenario = struct {
    name: []const u8,
    request: []const u8,
    status: u16 = 200,
};

const scenarios = [_]Scenario{
    .{ .name = "plain text", .request = "GET /text HTTP/1.1\r\nHost: bench\r\n\r\n" },
    .{ .name = "JSON out", .request = "GET /todos/42 HTTP/1.1\r\nHost: bench\r\n\r\n" },
    .{
        .name = "JSON in and out",
        .request = "POST /todos HTTP/1.1\r\nHost: bench\r\nContent-Type: application/json\r\nContent-Length: 33\r\n\r\n{\"title\":\"Buy milk\",\"done\":false}",
        .status = 201,
    },
    .{ .name = "static file, 1.8 KiB", .request = "GET /index.html HTTP/1.1\r\nHost: bench\r\n\r\n" },
    .{ .name = "chain of 5 middleware", .request = "GET /chained HTTP/1.1\r\nHost: bench\r\n\r\n" },
};

/// Connections, and requests on each of them.
const Level = struct { connections: usize, requests: usize };

const levels = [_]Level{
    .{ .connections = 1, .requests = 20_000 },
    .{ .connections = 64, .requests = 3_000 },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: bench <directory of the static files>\n", .{});
        std.process.exit(2);
    }
    const public_dir = args[1];

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("zefir-http benchmark: {t} build, {t} {t}; the server and its clients in one process, over loopback\n\n", .{ builtin.mode, builtin.os.tag, builtin.cpu.arch });
    try out.flush();
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        try out.print("zio, {d} {s}\n", .{ executors, if (executors == 1) "executor" else "executors" });
        try out.print("  {s:<24} {s:>5} {s:>9} {s:>11} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "scenario", "conns", "requests", "requests/s", "p50 µs", "p90 µs", "p99 µs", "max µs" });
        try out.flush();
        try runAll(runtime.io(), out, public_dir);
        try out.print("\n", .{});
        try out.flush();
    }
}

fn runAll(io: Io, out: *Io.Writer, public_dir: []const u8) !void {
    var app: App = .{};
    var native = try http.native.Backend.init(gpa, .{ .address = "127.0.0.1", .port = 0 });
    defer native.deinit();
    var server = try http.Server.init(gpa, .{
        .controllers = .{&app},
    }, .{
        .listen = .{ .backend = native.backend() },
        .static = &.{http.static("/", .{ .root = public_dir })},
    });
    defer server.deinit(io);
    try server.start(io);
    for (scenarios) |scenario| {
        for (levels) |level| try measure(io, out, native.port(), scenario, level);
    }
    try server.shutdown(io, far(io));
}

/// A deadline 30 s away, for the stop at the end.
fn far(io: Io) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
}

/// One client: `latencies.len` requests on one connection, the time of
/// each in nanoseconds.
const Client = struct {
    port: u16,
    scenario: Scenario,
    latencies: []u64,
    failure: ?anyerror = null,

    fn run(c: *Client, io: Io) void {
        c.requests(io) catch |err| {
            c.failure = err;
        };
    }

    fn requests(c: *Client, io: Io) !void {
        const address: net.IpAddress = try .parseIp4("127.0.0.1", c.port);
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var buffer: [16 << 10]u8 = undefined;
        var kept: usize = 0;
        for (c.latencies) |*latency| {
            const start = Io.Clock.awake.now(io);
            try send(io, stream, c.scenario.request);
            const status = try readResponse(io, stream, &buffer, &kept);
            if (status != c.scenario.status) return error.UnexpectedStatus;
            latency.* = @intCast(start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
        }
    }
};

fn send(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{rest} } });
        rest = rest[try result.net_write..];
    }
}

/// Reads one response whose body has a `Content-Length`, from what is
/// kept in `buffer` and from the connection; keeps what follows it.
/// Returns its status.
fn readResponse(io: Io, stream: net.Stream, buffer: []u8, kept: *usize) !u16 {
    while (true) {
        if (std.mem.find(u8, buffer[0..kept.*], "\r\n\r\n")) |end| {
            const head = buffer[0 .. end + 4];
            const field = "\r\ncontent-length:";
            const at = std.ascii.findIgnoreCase(head, field) orelse return error.NoContentLength;
            const value_end = std.mem.findPos(u8, head, at + field.len, "\r\n").?;
            const length = try std.fmt.parseInt(usize, std.mem.trim(u8, head[at + field.len .. value_end], " "), 10);
            const status = try std.fmt.parseInt(u16, head[9..12], 10);
            const total = end + 4 + length;
            if (total > buffer.len) return error.ResponseTooLarge;
            while (kept.* < total) try fill(io, stream, buffer, kept);
            std.mem.copyForwards(u8, buffer[0 .. kept.* - total], buffer[total..kept.*]);
            kept.* -= total;
            return status;
        }
        try fill(io, stream, buffer, kept);
    }
}

fn fill(io: Io, stream: net.Stream, buffer: []u8, kept: *usize) !void {
    if (kept.* == buffer.len) return error.ResponseTooLarge;
    var data: [1][]u8 = .{buffer[kept.*..]};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } });
    const read = try result.net_read;
    if (read.data_len == 0) return error.EndOfStream;
    kept.* += read.data_len;
}

/// Runs `level` of `scenario` after a warm-up, and prints its line.
fn measure(io: Io, out: *Io.Writer, port: u16, scenario: Scenario, level: Level) !void {
    const warm_up = try load(io, port, scenario, level.connections, @max(level.requests / 10, 100));
    gpa.free(warm_up.all);
    const latencies = try load(io, port, scenario, level.connections, level.requests);
    defer gpa.free(latencies.all);
    std.mem.sort(u64, latencies.all, {}, std.sort.asc(u64));
    const n = latencies.all.len;
    const seconds = @as(f64, @floatFromInt(latencies.took.nanoseconds)) / std.time.ns_per_s;
    try out.print("  {s:<24} {d:>5} {d:>9} {d:>11.0} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1}\n", .{
        scenario.name,
        level.connections,
        n,
        @as(f64, @floatFromInt(n)) / seconds,
        micros(latencies.all[n * 50 / 100]),
        micros(latencies.all[n * 90 / 100]),
        micros(latencies.all[n * 99 / 100]),
        micros(latencies.all[n - 1]),
    });
    try out.flush();
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

const Latencies = struct { all: []u64, took: Io.Duration };

/// `connections` clients at once, `requests` each: the latency of every
/// request, and the time of all.
fn load(io: Io, port: u16, scenario: Scenario, connections: usize, requests: usize) !Latencies {
    const all = try gpa.alloc(u64, connections * requests);
    errdefer gpa.free(all);
    const clients = try gpa.alloc(Client, connections);
    defer gpa.free(clients);
    for (clients, 0..) |*c, i| c.* = .{ .port = port, .scenario = scenario, .latencies = all[i * requests ..][0..requests] };
    const start = Io.Clock.awake.now(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (clients) |*c| try group.concurrent(io, Client.run, .{ c, io });
    try group.await(io);
    const took = start.durationTo(Io.Clock.awake.now(io));
    for (clients) |c| if (c.failure) |err| {
        std.debug.print("{s}: a client failed with {t}\n", .{ scenario.name, err });
        return err;
    };
    return .{ .all = all, .took = took };
}
