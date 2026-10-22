//! A minimal application container, only in tests. It runs `rpc.RawServer`
//! and `rpc.Server` through their public lifecycle alone, as the
//! specification's acceptance criteria ask. A component is any type with
//! `start`, `wait` and `shutdown(io, deadline)`. Their `requestStop` is for
//! a signal handler of an App; this one stops its components with
//! `shutdown` alone, one after another, within one deadline 30 s away.

const std = @import("std");
const core = @import("core");
const RawServer = @import("../engine/RawServer.zig");
const RawClient = @import("../engine/RawClient.zig");
const Context = @import("../engine/Context.zig").Context;
const Server = @import("../app/Server.zig");
const contract = @import("../app/contract.zig");
const MemoryTransport = @import("MemoryTransport.zig");
const far = @import("../wait.zig").far;

pub const MiniApp = struct {
    /// Set by `requestStop`, or by a component that stopped by itself.
    stop: std.Io.Event = .unset,
    mutex: std.Io.Mutex = .init,
    /// The error of the first component that stopped by itself.
    breakdown: ?anyerror = null,

    /// Asks `run` to stop every component. From any task; never waits.
    pub fn requestStop(app: *MiniApp, io: std.Io) void {
        app.stop.set(io);
    }

    /// Starts `components`, a tuple of pointers, in order; when one does not
    /// start, shuts down those already started. Then waits for
    /// `requestStop` or for the first component that stops by itself, and
    /// shuts every component down. Shutdowns go last first, each to its
    /// end before the next. The App never frees the components: their
    /// owner does, once `run` has returned. The error, the first of these
    /// that holds:
    ///
    /// - `error.ShutdownTimeout` of a shutdown: a handler still runs, so
    ///   the owner ends the process instead of freeing the components;
    /// - `error.Canceled` of a shutdown: the App's task was canceled while a
    ///   component stopped, and the component goes on stopping;
    /// - `error.Canceled`: the App's task was canceled while it waited;
    /// - the error of the start that failed, or of the component that broke;
    /// - the first other error of a shutdown.
    pub fn run(app: *MiniApp, io: std.Io, components: anytype) anyerror!void {
        const n = components.len;
        inline for (0..n) |i| {
            components[i].start(io) catch |err| {
                if (stopFirst(io, components, i)) |stop_err| if (weight(stop_err) > 0) return stop_err;
                return err;
            };
        }
        var watchers: [n]?std.Io.Future(void) = @splat(null);
        inline for (0..n) |i| {
            watchers[i] = io.concurrent(Watcher(@TypeOf(components[i])).watch, .{ app, io, components[i] }) catch |err| none: {
                app.broke(io, err);
                break :none null;
            };
        }
        const canceled = if (app.stop.wait(io)) |_| false else |_| true;
        const failed = stopFirst(io, components, n);
        // Nothing may still wait on a component once its owner frees it;
        // and once no watcher runs, `breakdown` stays as it is.
        for (&watchers) |*watcher| if (watcher.*) |*future| future.cancel(io);
        if (failed) |err| if (weight(err) > 0) return err;
        if (canceled) return error.Canceled;
        if (app.breakdown) |err| return err;
        if (failed) |err| return err;
    }

    fn broke(app: *MiniApp, io: std.Io, err: anyerror) void {
        app.mutex.lockUncancelable(io);
        defer app.mutex.unlock(io);
        if (app.breakdown == null) app.breakdown = err;
        app.stop.set(io);
    }

    /// Shuts down the first `count` components, last first, each to its end
    /// before the next. The weightiest error of a shutdown, the first of
    /// equal ones.
    fn stopFirst(io: std.Io, components: anytype, comptime count: usize) ?anyerror {
        const deadline = far(io);
        var worst: ?anyerror = null;
        comptime var i = count;
        inline while (i > 0) {
            i -= 1;
            components[i].shutdown(io, deadline) catch |err| {
                if (worst == null or weight(err) > weight(worst.?)) worst = err;
            };
        }
        return worst;
    }

    /// How much an error of a shutdown weighs for the owner: a handler
    /// still runs, a stop cut short, or nothing that stops it freeing the
    /// components.
    fn weight(err: anyerror) u2 {
        if (err == error.ShutdownTimeout) return 2;
        if (err == error.Canceled) return 1;
        return 0;
    }

    /// Waits until a component stops by itself; the App cancels the wait
    /// once it stops the components.
    fn Watcher(comptime Component: type) type {
        return struct {
            fn watch(app: *MiniApp, io: std.Io, component: Component) void {
                component.wait(io) catch |err| {
                    const failure: anyerror = err;
                    if (failure == error.Canceled) return;
                    return app.broke(io, failure);
                };
                app.stop.set(io);
            }
        };
    }
};

const testing = std.testing;

const echo_route: @import("../model.zig").Route = .{ .service = "app", .version = 1, .method = "echo" };

const Echo = struct {
    fn handle(_: *anyopaque, _: *Context, request: []const u8) anyerror![]const u8 {
        return request;
    }
};

var echo_state: u8 = 0;
const echo_methods = [_]RawServer.Method{.{ .route = echo_route, .handler = .{ .ptr = &echo_state, .handle = Echo.handle } }};

fn runApp(app: *MiniApp, io: std.Io, first: *RawServer, second: *RawServer) anyerror!void {
    return app.run(io, .{ first, second });
}

/// Waits until both servers run, ten seconds at most.
fn waitRunning(io: std.Io, servers: []const *RawServer) !void {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    for (servers) |server| {
        while (server.state() != .running) {
            if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
}

fn expectEcho(io: std.Io, memory: *MemoryTransport, body: []const u8) !void {
    var client: RawClient = try .init(testing.allocator, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    var result = try client.call(io, .root, echo_route, body, .{ .timeout = .fromSeconds(5) });
    defer result.deinit();
    try testing.expect(result.response.status == .ok);
    try testing.expectEqualStrings(body, result.response.body);
}

test "an App starts two servers, serves through both, and stops them on request" {
    const io = testing.io;
    var first_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer first_memory.deinit(io);
    var second_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer second_memory.deinit(io);
    var first: RawServer = try .init(testing.allocator, .{ .transport = first_memory.serverTransport(), .methods = &echo_methods });
    defer first.deinit(io);
    var second: RawServer = try .init(testing.allocator, .{ .transport = second_memory.serverTransport(), .methods = &echo_methods });
    defer second.deinit(io);

    var app: MiniApp = .{};
    var running = try io.concurrent(runApp, .{ &app, io, &first, &second });
    defer running.cancel(io) catch {};
    try waitRunning(io, &.{ &first, &second });
    try expectEcho(io, &first_memory, "first");
    try expectEcho(io, &second_memory, "second");
    app.requestStop(io);
    try running.await(io);
    try testing.expectEqual(RawServer.State.stopped, first.state());
    try testing.expectEqual(RawServer.State.stopped, second.state());
}

test "when the second server does not start, the App stops the first and returns the error" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var first: RawServer = try .init(testing.allocator, .{ .transport = memory.serverTransport(), .methods = &echo_methods });
    defer first.deinit(io);
    // The same address: its transport is taken by the first.
    var second: RawServer = try .init(testing.allocator, .{ .transport = memory.serverTransport(), .methods = &echo_methods });
    defer second.deinit(io);

    var app: MiniApp = .{};
    try testing.expectError(error.AddressInUse, app.run(io, .{ &first, &second }));
    try testing.expectEqual(RawServer.State.stopped, first.state());
    try testing.expectEqual(RawServer.State.stopped, second.state());
}

test "a server whose transport breaks stops the App and both servers" {
    const io = testing.io;
    var first_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer first_memory.deinit(io);
    var second_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer second_memory.deinit(io);
    var first: RawServer = try .init(testing.allocator, .{ .transport = first_memory.serverTransport(), .methods = &echo_methods });
    defer first.deinit(io);
    var second: RawServer = try .init(testing.allocator, .{ .transport = second_memory.serverTransport(), .methods = &echo_methods });
    defer second.deinit(io);
    // The engine warns that the transport broke.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    var app: MiniApp = .{};
    var running = try io.concurrent(runApp, .{ &app, io, &first, &second });
    defer running.cancel(io) catch {};
    try waitRunning(io, &.{ &first, &second });
    first_memory.failServer(io, error.Unavailable);
    try testing.expectError(error.Unavailable, running.await(io));
    try testing.expectEqual(RawServer.State.stopped, first.state());
    try testing.expectEqual(RawServer.State.stopped, second.state());
}

/// A handler deaf to cancelation: it ends only once its gate opens.
const Deaf = struct {
    entered: std.atomic.Value(bool) = .init(false),
    gate: std.Io.Event = .unset,

    fn handle(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
        const deaf: *Deaf = @ptrCast(@alignCast(ptr));
        const io = ctx.io();
        deaf.entered.store(true, .release);
        deaf.gate.waitUncancelable(io);
        return request;
    }
};

fn callDeaf(io: std.Io, memory: *MemoryTransport) void {
    var client: RawClient = RawClient.init(testing.allocator, .{ .transport = memory.clientTransport() }) catch return;
    defer client.deinit();
    var result = client.call(io, .root, echo_route, "deaf", .{ .timeout = .fromSeconds(30) }) catch return;
    result.deinit();
}

test "a shutdown that runs out of time is fatal: the App reports it and leaves the servers to their owner" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var other_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer other_memory.deinit(io);
    var deaf: Deaf = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = .{ .ptr = &deaf, .handle = Deaf.handle } }},
        .shutdown_grace = .fromMilliseconds(50),
    });
    defer server.deinit(io);
    var other: RawServer = try .init(testing.allocator, .{ .transport = other_memory.serverTransport(), .methods = &echo_methods });
    defer other.deinit(io);
    // Whatever happens, the handler ends before the server's deinit.
    defer deaf.gate.set(io);

    var app: MiniApp = .{};
    var running = try io.concurrent(runApp, .{ &app, io, &server, &other });
    defer running.cancel(io) catch {};
    try waitRunning(io, &.{ &server, &other });
    var caller = try io.concurrent(callDeaf, .{ io, &memory });
    defer caller.cancel(io);
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    while (!deaf.entered.load(.acquire)) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    app.requestStop(io);
    // The grace, then a second for the canceled handler to end.
    try testing.expectError(error.ShutdownTimeout, running.await(io));
    // The App stopped what it could and freed nothing: the deaf server
    // drains on, the other one stopped.
    try testing.expectEqual(RawServer.State.draining, server.state());
    try testing.expectEqual(RawServer.State.stopped, other.state());
    // A process would end here. The test lets the handler end, then frees.
    deaf.gate.set(io);
    caller.await(io);
}

fn waitEntered(io: std.Io, deaf: *const Deaf) !void {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    while (!deaf.entered.load(.acquire)) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a breakdown of one server does not hide a shutdown of another that runs out of time" {
    const io = testing.io;
    var broken_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer broken_memory.deinit(io);
    var deaf_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer deaf_memory.deinit(io);
    var deaf: Deaf = .{};
    var broken: RawServer = try .init(testing.allocator, .{ .transport = broken_memory.serverTransport(), .methods = &echo_methods });
    defer broken.deinit(io);
    var deaf_server: RawServer = try .init(testing.allocator, .{
        .transport = deaf_memory.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = .{ .ptr = &deaf, .handle = Deaf.handle } }},
        .shutdown_grace = .fromMilliseconds(50),
    });
    defer deaf_server.deinit(io);
    defer deaf.gate.set(io);
    // The engine warns that the transport broke.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    var app: MiniApp = .{};
    var running = try io.concurrent(runApp, .{ &app, io, &broken, &deaf_server });
    defer running.cancel(io) catch {};
    try waitRunning(io, &.{ &broken, &deaf_server });
    var caller = try io.concurrent(callDeaf, .{ io, &deaf_memory });
    defer caller.cancel(io);
    try waitEntered(io, &deaf);
    broken_memory.failServer(io, error.Unavailable);
    // The owner must not free the deaf server: that wins over the breakdown.
    try testing.expectError(error.ShutdownTimeout, running.await(io));
    try testing.expectEqual(RawServer.State.draining, deaf_server.state());
    try testing.expectEqual(RawServer.State.stopped, broken.state());
    deaf.gate.set(io);
    caller.await(io);
}

/// A component whose start fails once its gate opens.
const FailsToStart = struct {
    gate: std.Io.Event = .unset,

    pub fn start(f: *FailsToStart, io: std.Io) !void {
        try f.gate.wait(io);
        return error.AddressInUse;
    }

    pub fn wait(f: *FailsToStart, io: std.Io) !void {
        _ = f;
        _ = io;
    }

    pub fn requestStop(f: *FailsToStart, io: std.Io) void {
        _ = f;
        _ = io;
    }

    pub fn shutdown(f: *FailsToStart, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        _ = f;
        _ = io;
        _ = deadline;
    }
};

fn runWithFailing(app: *MiniApp, io: std.Io, first: *RawServer, second: *FailsToStart) anyerror!void {
    return app.run(io, .{ first, second });
}

test "when the stop of the started ones runs out of time after a failed start, that wins over the start error" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var deaf: Deaf = .{};
    var first: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = .{ .ptr = &deaf, .handle = Deaf.handle } }},
        .shutdown_grace = .fromMilliseconds(50),
    });
    defer first.deinit(io);
    defer deaf.gate.set(io);
    var second: FailsToStart = .{};

    var app: MiniApp = .{};
    var running = try io.concurrent(runWithFailing, .{ &app, io, &first, &second });
    defer running.cancel(io) catch {};
    defer second.gate.set(io);
    try waitRunning(io, &.{&first});
    var caller = try io.concurrent(callDeaf, .{ io, &memory });
    defer caller.cancel(io);
    try waitEntered(io, &deaf);
    second.gate.set(io);
    try testing.expectError(error.ShutdownTimeout, running.await(io));
    try testing.expectEqual(RawServer.State.draining, first.state());
    deaf.gate.set(io);
    caller.await(io);
}

/// A component that writes when it starts, begins to stop and has stopped.
const Logged = struct {
    name: u8,
    log: *Log,
    stopped: std.Io.Event = .unset,

    const Log = struct {
        entries: [8]Entry = undefined,
        len: std.atomic.Value(usize) = .init(0),

        const Entry = struct { name: u8, what: enum { start, stop_begun, stop_ended } };

        fn add(log: *Log, entry: Entry) void {
            const i = log.len.fetchAdd(1, .acq_rel);
            if (i < log.entries.len) log.entries[i] = entry;
        }

        fn written(log: *const Log) []const Entry {
            return log.entries[0..@min(log.len.load(.acquire), log.entries.len)];
        }
    };

    pub fn start(l: *Logged, io: std.Io) !void {
        _ = io;
        l.log.add(.{ .name = l.name, .what = .start });
    }

    pub fn wait(l: *Logged, io: std.Io) !void {
        try l.stopped.wait(io);
    }

    pub fn requestStop(l: *Logged, io: std.Io) void {
        _ = io;
        l.log.add(.{ .name = l.name, .what = .stop_begun });
    }

    pub fn shutdown(l: *Logged, io: std.Io, _: std.Io.Clock.Timestamp) !void {
        l.log.add(.{ .name = l.name, .what = .stop_begun });
        // A component that takes a while to stop.
        try io.sleep(.fromMilliseconds(20), .awake);
        l.log.add(.{ .name = l.name, .what = .stop_ended });
        l.stopped.set(io);
    }
};

test "the App stops its components last first, each before the next begins" {
    const io = testing.io;
    var log: Logged.Log = .{};
    var a: Logged = .{ .name = 'a', .log = &log };
    var b: Logged = .{ .name = 'b', .log = &log };
    var app: MiniApp = .{};
    app.requestStop(io);
    try app.run(io, .{ &a, &b });
    const expected = [_]Logged.Log.Entry{
        .{ .name = 'a', .what = .start },
        .{ .name = 'b', .what = .start },
        .{ .name = 'b', .what = .stop_begun },
        .{ .name = 'b', .what = .stop_ended },
        .{ .name = 'a', .what = .stop_begun },
        .{ .name = 'a', .what = .stop_ended },
    };
    try testing.expectEqualSlices(Logged.Log.Entry, &expected, log.written());
}

// The same App runs servers of the application, `rpc.Server`.

const EchoRequest = struct { text: []const u8 };

const EchoApi = contract.Contract(.{
    .name = "app",
    .version = 1,
    .methods = .{ .echo = contract.method(EchoRequest, EchoRequest) },
});

const AppEcho = struct {
    pub const rpc_handler = contract.implement(EchoApi, .{});

    pub fn echo(self: *AppEcho, ctx: *Context, req: EchoRequest) !EchoRequest {
        _ = self;
        _ = ctx;
        return req;
    }
};

/// An echo deaf to cancelation: it ends only once its gate opens.
const DeafEcho = struct {
    entered: std.atomic.Value(bool) = .init(false),
    gate: std.Io.Event = .unset,

    pub const rpc_handler = contract.implement(EchoApi, .{ .defaults = .{ .timeout_ms = 30_000 } });

    pub fn echo(self: *DeafEcho, ctx: *Context, req: EchoRequest) !EchoRequest {
        self.entered.store(true, .release);
        self.gate.waitUncancelable(ctx.io());
        return req;
    }
};

fn runServers(app: *MiniApp, io: std.Io, first: *Server, second: *Server) anyerror!void {
    return app.run(io, .{ first, second });
}

/// Waits until both servers run, ten seconds at most.
fn waitServing(io: std.Io, servers: []const *Server) !void {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    for (servers) |server| {
        while (server.state() != .running) {
            if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
}

test "an App starts two rpc.Server, serves through both, and stops them on request" {
    const io = testing.io;
    var first_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer first_memory.deinit(io);
    var second_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer second_memory.deinit(io);
    var echo: AppEcho = .{};
    var first: Server = try .init(testing.allocator, .{ .handlers = .{&echo} }, .{ .transport = first_memory.serverTransport() });
    defer first.deinit(io);
    var second: Server = try .init(testing.allocator, .{ .handlers = .{&echo} }, .{ .transport = second_memory.serverTransport() });
    defer second.deinit(io);

    var app: MiniApp = .{};
    var running = try io.concurrent(runServers, .{ &app, io, &first, &second });
    defer running.cancel(io) catch {};
    try waitServing(io, &.{ &first, &second });
    try expectEcho(io, &first_memory, "{\"text\":\"first\"}");
    try expectEcho(io, &second_memory, "{\"text\":\"second\"}");
    app.requestStop(io);
    try running.await(io);
    try testing.expectEqual(Server.State.stopped, first.state());
    try testing.expectEqual(Server.State.stopped, second.state());
}

test "when the second rpc.Server does not start, the App stops the first and returns the error" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var echo: AppEcho = .{};
    var first: Server = try .init(testing.allocator, .{ .handlers = .{&echo} }, .{ .transport = memory.serverTransport() });
    defer first.deinit(io);
    // The same address: its transport is taken by the first.
    var second: Server = try .init(testing.allocator, .{ .handlers = .{&echo} }, .{ .transport = memory.serverTransport() });
    defer second.deinit(io);

    var app: MiniApp = .{};
    try testing.expectError(error.AddressInUse, app.run(io, .{ &first, &second }));
    try testing.expectEqual(Server.State.stopped, first.state());
    try testing.expectEqual(Server.State.stopped, second.state());
}

fn callDeafEcho(io: std.Io, memory: *MemoryTransport) void {
    var client: RawClient = RawClient.init(testing.allocator, .{ .transport = memory.clientTransport() }) catch return;
    defer client.deinit();
    var result = client.call(io, .root, echo_route, "{\"text\":\"deaf\"}", .{ .timeout = .fromSeconds(30) }) catch return;
    result.deinit();
}

test "an rpc.Server whose shutdown runs out of time: the App reports it and leaves the servers to their owner" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var other_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer other_memory.deinit(io);
    var deaf: DeafEcho = .{};
    var echo: AppEcho = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&deaf},
    }, .{
        .transport = memory.serverTransport(),
        .shutdown_grace = std.Io.Duration.fromMilliseconds(50),
    });
    defer server.deinit(io);
    var other: Server = try .init(testing.allocator, .{ .handlers = .{&echo} }, .{ .transport = other_memory.serverTransport() });
    defer other.deinit(io);
    // Whatever happens, the handler ends before the server's deinit.
    defer deaf.gate.set(io);

    var app: MiniApp = .{};
    var running = try io.concurrent(runServers, .{ &app, io, &server, &other });
    defer running.cancel(io) catch {};
    try waitServing(io, &.{ &server, &other });
    var caller = try io.concurrent(callDeafEcho, .{ io, &memory });
    defer caller.cancel(io);
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    while (!deaf.entered.load(.acquire)) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    app.requestStop(io);
    try testing.expectError(error.ShutdownTimeout, running.await(io));
    try testing.expectEqual(Server.State.draining, server.state());
    try testing.expectEqual(Server.State.stopped, other.state());
    deaf.gate.set(io);
    caller.await(io);
}
