//! The tests of zefir.App's lifecycle: the start in creation order with its
//! rollback, the watchers and fail-fast, the stop in two phases within one
//! deadline, and the states and the API of design §9, on the gated beans of
//! gates.zig.
const std = @import("std");
const testing = std.testing;
const zapp = @import("../../app.zig");
const gates = @import("gates.zig");

const Io = std.Io;
const Rig = gates.Rig;

fn budget(ms: i64) zapp.Options {
    return .{ .shutdown_timeout = .fromMilliseconds(ms) };
}

/// The calls a test runs in a task of its own.
fn Calls(comptime App: type) type {
    return struct {
        fn start(app: *App) anyerror!void {
            return app.start();
        }
        fn wait(app: *App) anyerror!void {
            return app.wait();
        }
    };
}

/// Waits, ten seconds at most, until the stop task of `app` has returned.
fn awaitEnded(app: anytype) !void {
    return gates.within(&app.internal.block.runtime.ended, app.internal.io, .fromSeconds(10));
}

/// Waits, ten seconds at most, until `app` is in `state`.
fn awaitState(app: anytype, state: zapp.State) !void {
    const io = app.internal.io;
    const until = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (app.state() != state) {
        if (Io.Clock.awake.now(io).nanoseconds >= until.nanoseconds) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn expectFailure(app: anytype, bean: []const u8, step: zapp.Failure.Step, err: anyerror) !void {
    const failure = app.failure() orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(bean, failure.bean);
    try testing.expectEqual(step, failure.step);
    try testing.expectEqual(err, failure.err);
}

/// Silences App's warnings in a test that makes App warn; the standard
/// runner prints them otherwise.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "start runs the beans in creation order; a stop asks all, then shuts down in reverse" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.C }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try app.start();
        try rig.expect("start", &.{ "A", "B", "C" });
        try testing.expectEqual(zapp.State.running, app.state());
        app.requestStop();
        try app.wait();
        try testing.expectEqual(zapp.State.stopped, app.state());
        try rig.expect("requestStop", &.{ "A", "B", "C" });
        try rig.expect("shutdown", &.{ "C", "B", "A" });
        // Phase 1 asks every bean before phase 2 shuts the first one down.
        try testing.expect(rig.position("requestStop", "C").? < rig.position("shutdown", "C").?);
        try testing.expect(app.failure() == null);
    }
    app.deinit();
    try rig.expect("deinit", &.{ "C", "B", "A" });
}

test "a start that fails rolls the started ones back in reverse and returns its error" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.Second, gates.Third }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("Third").start = .fails;
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try testing.expectError(error.StartFailed, app.start());
        try rig.expect("start", &.{ "First", "Second", "Third" });
        try rig.expect("shutdown", &.{ "Second", "First" });
        try expectFailure(&app, "Root.Third", .start, error.StartFailed);
        try testing.expectEqual(zapp.State.failed, app.state());
        try testing.expectError(error.StartFailed, app.wait());
    }
    app.deinit();
    try rig.expect("deinit", &.{ "Third", "Second", "First" });
}

test "the rollback gets the whole budget" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.Second }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("Second").start = .fails;
    rig.of("Second").sleep = .fromMilliseconds(200);
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, budget(100));
    defer app.deinit();
    try testing.expectError(error.StartFailed, app.start());
    // The deadline counts from the rollback's start, not from the start of `start`.
    const failed_at = rig.of("Second").failed_at.?;
    const deadline = rig.of("First").deadline.?;
    try testing.expect(deadline.raw.nanoseconds >= failed_at.addDuration(.fromMilliseconds(100 - 20)).nanoseconds);
}

test "a rollback that runs out of time: start returns ShutdownTimeout, failure keeps the start error" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.Second }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("First").shutdown = .deaf;
    rig.of("Second").start = .fails;
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, budget(50));
    try testing.expectError(error.ShutdownTimeout, app.start());
    try testing.expectError(error.ShutdownTimeout, app.wait());
    try expectFailure(&app, "Root.Second", .start, error.StartFailed);
    try testing.expectEqual(zapp.State.failed, app.state());
    // The stop task still waits in First's shutdown: deinit frees nothing.
    app.deinit();
    try rig.expect("deinit", &.{});
    rig.open("First");
    try awaitEnded(&app);
    app.deinit();
    try rig.expect("deinit", &.{ "Second", "First" });
}

test "no task for a watcher: the start rolls back with ConcurrencyUnavailable" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    // The stop task takes the one task there is; the watcher gets none.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try testing.expectError(error.ConcurrencyUnavailable, app.start());
        try rig.expect("start", &.{ "A", "Waiter" });
        try rig.expect("shutdown", &.{ "Waiter", "A" });
        try expectFailure(&app, "Root.Waiter", .start, error.ConcurrencyUnavailable);
        try testing.expectEqual(zapp.State.failed, app.state());
    }
    app.deinit();
    try rig.expect("deinit", &.{ "Waiter", "A" });
}

test "no task for the stop: start returns ConcurrencyUnavailable and starts nothing" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try testing.expectError(error.ConcurrencyUnavailable, app.start());
        try rig.expect("start", &.{});
        try testing.expectEqual(zapp.State.failed, app.state());
        try testing.expect(app.failure() == null);
        try testing.expectError(error.ConcurrencyUnavailable, app.wait());
    }
    app.deinit();
    try rig.expect("deinit", &.{ "Waiter", "A" });
}

test "requestStop during start: the current start ends, the rest never start" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.C }, .values = &.{*Rig} };
    };
    const App = zapp.App(Root);
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").start = .held;
    var app = try App.init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    var starting = try io.concurrent(Calls(App).start, .{&app});
    defer starting.cancel(io) catch {};
    try rig.entered("B");
    app.requestStop();
    try testing.expectEqual(zapp.State.stopping, app.state());
    rig.open("B");
    try starting.await(io);
    try app.wait();
    try testing.expectEqual(zapp.State.stopped, app.state());
    try rig.expect("start", &.{ "A", "B" });
    try rig.expect("shutdown", &.{ "B", "A" });
    try testing.expect(app.failure() == null);
}

test "a bean that breaks while the next ones start fails the start" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.Waiter, gates.B }, .values = &.{*Rig} };
    };
    const App = zapp.App(Root);
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").start = .held;
    var app = try App.init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    var starting = try io.concurrent(Calls(App).start, .{&app});
    defer starting.cancel(io) catch {};
    try rig.entered("B");
    rig.end("Waiter", error.Broken);
    // The watcher saw it while App was starting.
    try awaitState(&app, .stopping);
    rig.open("B");
    try testing.expectError(error.Broken, starting.await(io));
    try expectFailure(&app, "Root.Waiter", .wait, error.Broken);
    try testing.expectError(error.Broken, app.wait());
    try testing.expectEqual(zapp.State.failed, app.state());
    try rig.expect("shutdown", &.{ "B", "Waiter" });
}
