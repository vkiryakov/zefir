//! A minimal application container, only in tests. It shows that an App can
//! run `rpc.RawServer` later through its public lifecycle alone, with no
//! change to the server's API, as the specification's acceptance criteria
//! ask. A component is any type with `start`, `wait`, `requestStop` and
//! `shutdown`: `rpc.RawServer` now, `rpc.Server` later.

const std = @import("std");
const core = @import("core");
const RawServer = @import("../engine/RawServer.zig");
const RawClient = @import("../engine/RawClient.zig");
const Context = @import("../engine/Context.zig").Context;
const MemoryTransport = @import("MemoryTransport.zig");

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
    /// start, shuts down those already started, last first, and returns its
    /// error. Then waits for `requestStop` or for the first component that
    /// stops by itself, and shuts every component down: all begin to stop
    /// at once, and the App waits for them last first. Returns the error of
    /// the component that broke, else the first error of a shutdown.
    /// `error.ShutdownTimeout` is fatal: a handler still runs, so the owner
    /// ends the process instead of freeing the components. The App never
    /// frees them: their owner does, once `run` has returned.
    pub fn run(app: *MiniApp, io: std.Io, components: anytype) anyerror!void {
        const n = components.len;
        inline for (0..n) |i| {
            components[i].start(io) catch |err| {
                _ = stopFirst(io, components, i);
                return err;
            };
        }
        var watchers: [n]?std.Io.Future(void) = @splat(null);
        // Nothing may still wait on a component once its owner frees it.
        defer for (&watchers) |*watcher| if (watcher.*) |*future| future.cancel(io);
        inline for (0..n) |i| {
            if (app.breakdown == null) {
                watchers[i] = io.concurrent(Watcher(@TypeOf(components[i])).watch, .{ app, io, components[i] }) catch |err| none: {
                    app.broke(io, err);
                    break :none null;
                };
            }
        }
        const canceled = if (app.stop.wait(io)) |_| false else |_| true;
        const failed = stopFirst(io, components, n);
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

    /// Stops the first `count` components: all begin to stop at once, then
    /// each is waited for, last first. The first error of a shutdown.
    fn stopFirst(io: std.Io, components: anytype, comptime count: usize) ?anyerror {
        comptime var i = count;
        inline while (i > 0) {
            i -= 1;
            components[i].requestStop(io);
        }
        var first: ?anyerror = null;
        comptime var j = count;
        inline while (j > 0) {
            j -= 1;
            components[j].shutdown(io) catch |err| {
                if (first == null) first = err;
            };
        }
        return first;
    }

    /// Waits until a component stops by itself; the App cancels the wait
    /// once it stops the components.
    fn Watcher(comptime Component: type) type {
        return struct {
            fn watch(app: *MiniApp, io: std.Io, component: Component) void {
                component.wait(io) catch |err| switch (err) {
                    error.Canceled => return,
                    else => return app.broke(io, err),
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
