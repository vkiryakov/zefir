//! Two servers whose grace the budget of App cuts: each learns the deadline
//! when the stop begins, so the work each cancels has the time its server
//! keeps for it, however long the other server takes to stop.

const std = @import("std");
const zefir = @import("zefir");
const runtime = @import("runtime");

const http = zefir.http;
const rpc = zefir.rpc;
const Io = std.Io;
const testing = std.testing;

const Req = struct { id: u64 };
const Resp = struct { id: u64 };

const SlowApi = rpc.Contract(.{
    .name = "slow",
    .version = 1,
    .methods = .{ .call = rpc.method(Req, Resp) },
    .errors = .{},
});

/// What the test sees of the work of the servers: a root value.
const Probe = struct {
    request_in: Io.Event = .unset,
    call_in: Io.Event = .unset,
    /// When the server canceled the request and the call: awake time, in
    /// nanoseconds.
    request_canceled_at: std.atomic.Value(i64) = .init(0),
    call_canceled_at: std.atomic.Value(i64) = .init(0),
};

/// `GET /slow`: works until the server cancels it, then 2 s more with
/// cancelation blocked, as a handler that finishes what it began. The
/// server keeps 1 s and `.finish_timeout` (2 s) for it.
const SlowController = struct {
    probe: *Probe,

    pub const http_routes = http.routes(.{ .methods = .{ .slow = http.get("/slow", .{}) } });

    pub fn slow(self: *SlowController, ctx: *http.Context) !void {
        const io = ctx.io();
        self.probe.request_in.set(io);
        var never: Io.Event = .unset;
        never.wait(io) catch |err| {
            self.probe.request_canceled_at.store(@intCast(Io.Clock.awake.now(io).nanoseconds), .release);
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            io.sleep(.fromMilliseconds(2000), .awake) catch {};
            return err;
        };
    }
};

/// A call that works until the server cancels it, then 500 ms more with
/// cancelation blocked. The server keeps 1 s for it.
const SlowHandler = struct {
    probe: *Probe,

    /// A limit of its own: the call lasts past the default 3 s.
    pub const rpc_handler = rpc.implement(SlowApi, .{ .defaults = .{ .timeout_ms = 30_000 } });

    pub fn call(self: *SlowHandler, ctx: *rpc.Context, req: Req) !Resp {
        const io = ctx.io();
        self.probe.call_in.set(io);
        var never: Io.Event = .unset;
        never.wait(io) catch |err| {
            self.probe.call_canceled_at.store(@intCast(Io.Clock.awake.now(io).nanoseconds), .release);
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            io.sleep(.fromMilliseconds(500), .awake) catch {};
            return err;
        };
        return .{ .id = req.id };
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{http.testing.Backend},
        .controllers = &.{SlowController},
        .handlers = &.{SlowHandler},
        .factories = &.{ Bus, Servers },
        .values = &.{*Probe},
    };

    pub const Bus = struct {
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    /// The rpc server is built last: before servers stopped together, App
    /// shut it down first, and the HTTP server learned the deadline only
    /// once the rpc server had stopped.
    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, backend: *http.testing.Backend, controllers: zefir.app.Controllers(Root)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{
                .listen = .{ .backend = backend.backend() },
                .shutdown_grace = .fromSeconds(10),
                .finish_timeout = .fromSeconds(2),
            });
        }

        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: zefir.app.Handlers(Root)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport(), .shutdown_grace = .fromSeconds(10) });
        }
    };
};

test "two servers whose grace the budget cuts: each gets the deadline when the stop begins" {
    try runtime.forEachRuntime(testing.allocator, stopBoth);
}

fn stopBoth(io: Io) !void {
    var dog: runtime.Watchdog = try .start(io, "two servers whose grace the budget cuts", 30);
    defer dog.stop(io);
    // The canceled request and call make the servers warn.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var probe: Probe = .{};
    var app = try zefir.App(Root).init(testing.allocator, io, .{&probe}, .{ .shutdown_timeout = .fromSeconds(4) });
    defer app.deinit();
    try app.start();
    var client: rpc.Client = try .init(testing.allocator, .{}, .{ .transport = app.get(rpc.testing.MemoryTransport).clientTransport() });
    defer client.deinit();

    // A request and a call at work, each on a task of its own, gathered
    // before the App stops whatever fails below.
    var request = try io.concurrent(requestSlow, .{ app.get(http.testing.Backend), io });
    defer request.await(io);
    var call = try io.concurrent(callSlow, .{ &client, io });
    defer call.await(io);
    try within(io, &probe.request_in, 5000);
    try within(io, &probe.call_in, 5000);

    // The deadline, 4 s away, ends the grace of the HTTP server 1 s,
    // .finish_timeout (2 s) and 250 ms before it: 750 ms after the stop
    // began; its request ends at 2750 ms, 1 s before the server's shutdown
    // gives up. The grace of the rpc server ends 2.25 s before the
    // deadline: 1750 ms; its call ends at 2250 ms, 500 ms within the second
    // the server keeps. Had the HTTP server learned the deadline only after
    // the rpc server stopped, at 2250 ms, its request would end at 4250 ms,
    // past its shutdown's 3750 ms: error.ShutdownTimeout.
    const asked = Io.Clock.awake.now(io);
    app.requestStop();
    const result = app.wait();
    const took = asked.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    const request_canceled = sinceMs(asked, probe.request_canceled_at.load(.acquire));
    const call_canceled = sinceMs(asked, probe.call_canceled_at.load(.acquire));
    result catch |err| {
        std.debug.print("wait returned {t} after {d} ms; the request was canceled at {d} ms, the call at {d} ms\n", .{ err, took, request_canceled, call_canceled });
        if (app.failure()) |failure| std.debug.print("failure: {s}, {t}, {t}\n", .{ failure.bean, failure.step, failure.err });
        return err;
    };
    try testing.expectEqual(zefir.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
    // The HTTP server cut its grace before the rpc server cut its own.
    if (request_canceled >= call_canceled) {
        std.debug.print("the request was canceled at {d} ms, the call at {d} ms\n", .{ request_canceled, call_canceled });
        return error.TestCanceledLate;
    }
    try testing.expect(took < 4000);
}

/// The request of `GET /slow`, which the stop cancels: its outcome does not matter.
fn requestSlow(backend: *http.testing.Backend, io: Io) void {
    if (backend.request(io, .{ .method = .GET, .target = "/slow" })) |res| {
        var r = res;
        r.deinit();
    } else |_| {}
}

/// The slow call, which the stop cancels: its outcome does not matter.
fn callSlow(client: *rpc.Client, io: Io) void {
    if (client.call(io, .root, SlowApi.call, .{ .id = 1 }, .{ .timeout = .fromSeconds(30) })) |res| {
        var r = res;
        r.deinit();
    } else |_| {}
}

/// Waits for `event`, `limit_ms` at most.
fn within(io: Io, event: *Io.Event, limit_ms: i64) !void {
    event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(limit_ms), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return error.TestTimeout,
        else => |e| return e,
    };
}

/// Milliseconds from `start` to the awake time `at`, in nanoseconds.
fn sinceMs(start: Io.Timestamp, at: i64) i64 {
    return start.durationTo(.{ .nanoseconds = at }).toMilliseconds();
}
