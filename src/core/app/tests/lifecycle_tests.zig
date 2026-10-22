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
        fn requestStop(app: *App) void {
            app.requestStop();
        }
    };
}

/// Waits, ten seconds at most, until the stop task of `app` has returned.
fn awaitEnded(app: anytype) !void {
    return gates.within(&app.internal.block.runtime.ended, app.internal.io, .fromSeconds(10));
}

/// Opens every gate, then waits, ten seconds at most, until the stop task of
/// `app` has returned. App's tasks use the block and the rig: a test that
/// fails calls this before either goes. For `defer`, or for `errdefer` up to
/// a `deinit` that frees the block.
fn settle(app: anytype, rig: *Rig) void {
    rig.release();
    awaitEnded(app) catch {};
}

/// Waits, ten seconds at most, until the stop task of `app` has given up on
/// a bean whose `wait` did not return by the deadline and gone on without it.
fn awaitGaveUp(app: anytype) !void {
    const rt = &app.internal.block.runtime;
    const io = app.internal.io;
    const until = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (true) {
        const gave_up = gave_up: {
            rt.mutex.lockUncancelable(io);
            defer rt.mutex.unlock(io);
            break :gave_up rt.keep_beans;
        };
        if (gave_up) return;
        if (Io.Clock.awake.now(io).nanoseconds >= until.nanoseconds) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits, ten seconds at most, until the event `what` of `who` came.
fn awaitEvent(rig: *Rig, what: []const u8, who: []const u8) !void {
    const until = Io.Clock.awake.now(rig.io).addDuration(.fromSeconds(10));
    while (rig.position(what, who) == null) {
        if (Io.Clock.awake.now(rig.io).nanoseconds >= until.nanoseconds) return error.TestTimeout;
        try rig.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits, ten seconds at most, until `app` has a cause.
fn awaitFailure(app: anytype) !void {
    const io = app.internal.io;
    const until = Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (app.failure() == null) {
        if (Io.Clock.awake.now(io).nanoseconds >= until.nanoseconds) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
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

test "start runs the beans in creation order; a stop asks all, then shuts them down" {
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
        // Three servers: their shutdowns run together.
        try rig.expectUnordered("shutdown", &.{ "A", "B", "C" });
        // Phase 1 asks every bean before phase 2 shuts the first one down.
        for ([_][]const u8{ "A", "B", "C" }) |who| try testing.expect(rig.position("requestStop", "C").? < rig.position("shutdown", who).?);
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
    {
        // Only up to the last deinit: it frees the block, which settle reads.
        errdefer settle(&app, &rig);
        try testing.expectError(error.ShutdownTimeout, app.start());
        try testing.expectError(error.ShutdownTimeout, app.wait());
        try expectFailure(&app, "Root.Second", .start, error.StartFailed);
        try testing.expectEqual(zapp.State.failed, app.state());
        // The stop task still waits in First's shutdown: deinit frees nothing.
        app.deinit();
        try rig.expect("deinit", &.{});
        rig.open("First");
        try awaitEnded(&app);
    }
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
        // Nor for the shutdowns of the servers: the stop task calls them
        // itself, last created first.
        try rig.expect("shutdown", &.{ "Waiter", "A" });
        try expectFailure(&app, "Root.Waiter", .start, error.ConcurrencyUnavailable);
        try testing.expectEqual(zapp.State.failed, app.state());
    }
    app.deinit();
    try rig.expect("deinit", &.{ "Waiter", "A" });
}

test "no task for the watcher of a bean without shutdown: the rollback waits in its wait itself" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{gates.Worker}, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    // The stop task takes one task, the Worker's own task the other; the
    // watcher gets none.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, budget(50));
    // The Worker's task runs until the test opens its gate, so the
    // rollback runs out of time in the Worker's wait.
    const started = app.start();
    app.deinit();
    try rig.expect("deinit", &.{});
    try testing.expectError(error.ShutdownTimeout, started);
    try expectFailure(&app, "Root.Worker", .start, error.ConcurrencyUnavailable);
    try testing.expectEqual(zapp.State.failed, app.state());
    rig.open("Worker");
    try awaitEnded(&app);
    // Its wait returned by itself: the Worker stopped, and deinit frees it.
    try rig.expect("waited", &.{"Worker"});
    app.deinit();
    try rig.expect("deinit", &.{"Worker"});
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
    try rig.expectUnordered("shutdown", &.{ "A", "B" });
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
    try rig.expectUnordered("shutdown", &.{ "Waiter", "B" });
}

test "a wait that ends with an error while running stops the App" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter, gates.B }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    rig.end("Waiter", error.Unavailable);
    try testing.expectError(error.Unavailable, app.wait());
    try expectFailure(&app, "Root.Waiter", .wait, error.Unavailable);
    try testing.expectEqual(zapp.State.stopped, app.state());
    // Every bean got its shutdown, the broken one too.
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter", "B" });
}

test "a wait that returns {} while running is UnexpectedStop" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    rig.end("Waiter", {});
    try testing.expectError(error.UnexpectedStop, app.wait());
    try expectFailure(&app, "Root.Waiter", .wait, error.UnexpectedStop);
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
}

test "a bean that is not ready does not stop the App" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Unready }, .values = &.{*Rig} };
    };
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    try testing.expect(!app.isReady());
    try io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectEqual(zapp.State.running, app.state());
    try rig.expect("shutdown", &.{});
    app.requestStop();
    try app.wait();
    try rig.expect("shutdown", &.{"A"});
    try testing.expect(app.failure() == null);
}

test "a wait deaf to cancelation without a shutdown: wait returns ShutdownTimeout at the deadline" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{gates.DeafWait}, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    // App frees no bean after it: the arena takes the block back, after
    // settle has waited for App's tasks.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(arena.allocator(), io, .{&rig}, budget(50));
    defer settle(&app, &rig);
    try app.start();
    const asked = Io.Clock.awake.now(io);
    app.requestStop();
    try testing.expectError(error.ShutdownTimeout, app.wait());
    const took = asked.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(took >= 50 - 16 and took < 2000);
    try testing.expectEqual(zapp.State.failed, app.state());
    try expectFailure(&app, "Root.DeafWait", .shutdown, error.ShutdownTimeout);
    // The stop task still gathers the deaf watcher: deinit frees nothing.
    app.deinit();
    try rig.expect("deinit", &.{});
    // A wait that returns before the stop task gives up on it returned in
    // time; this one returns after.
    try awaitGaveUp(&app);
    rig.open("DeafWait");
    try awaitEnded(&app);
    // App gave up on its wait at the deadline: deinit frees nothing even
    // once the stop task has ended, and takes back that task.
    app.deinit();
    try rig.expect("deinit", &.{});
    try testing.expect(app.internal.block.runtime.stop_task == null);
}

test "a wait App gave up on at the deadline: deinit frees nothing, as the bean's task may still run" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{gates.Worker}, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    // App frees no bean after it: the arena takes the block back, after
    // settle has waited for App's tasks.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(arena.allocator(), io, .{&rig}, budget(50));
    defer settle(&app, &rig);
    try app.start();
    app.requestStop();
    try testing.expectError(error.ShutdownTimeout, app.wait());
    try expectFailure(&app, "Root.Worker", .shutdown, error.ShutdownTimeout);
    // The gathering canceled the Worker's wait, and the stop task ended;
    // the Worker's task still runs.
    try awaitEnded(&app);
    app.deinit();
    try rig.expect("deinit", &.{});
    app.deinit();
    try rig.expect("deinit", &.{});
    // It takes back the ended stop task, so testing.allocator sees no leak.
    try testing.expect(app.internal.block.runtime.stop_task == null);
}

test "every shutdown gets one deadline: the start of the stop plus shutdown_timeout" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.C }, .values = &.{*Rig} };
    };
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{ .shutdown_timeout = .fromSeconds(5) });
    defer app.deinit();
    try app.start();
    const asked = Io.Clock.awake.now(io);
    app.requestStop();
    try app.wait();
    const deadline = rig.of("A").deadline.?;
    try testing.expectEqual(Io.Clock.awake, deadline.clock);
    try testing.expectEqual(deadline, rig.of("B").deadline.?);
    try testing.expectEqual(deadline, rig.of("C").deadline.?);
    // The stop task wakes after requestStop: on a busy machine, late.
    const after = asked.addDuration(.fromSeconds(5)).durationTo(deadline.raw).toMilliseconds();
    try testing.expect(after >= 0 and after < 1000);
}

test "a bean with wait and no shutdown: App waits for its wait" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.Lingering }, .values = &.{*Rig} };
    };
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("Lingering").sleep = .fromMilliseconds(100);
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    const asked = Io.Clock.awake.now(io);
    try app.shutdown();
    // One tick of the Windows timer early at most.
    try testing.expect(asked.durationTo(Io.Clock.awake.now(io)).toMilliseconds() >= 100 - 16);
    // It has requestStop, so App waits for it with the servers: its wait
    // returned before App went on to the others.
    try testing.expect(rig.position("waited", "Lingering").? < rig.position("shutdown", "First").?);
    try testing.expectEqual(zapp.State.stopped, app.state());
}

test "an error of one shutdown: the others still stop, and it becomes the cause" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.C }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("B").shutdown = .fails;
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    try testing.expectError(error.ShutdownFailed, app.shutdown());
    try expectFailure(&app, "Root.B", .shutdown, error.ShutdownFailed);
    try rig.expectUnordered("shutdown", &.{ "A", "B", "C" });
    try testing.expectEqual(zapp.State.stopped, app.state());
}

test "the first cause stays: a shutdown error after a breakdown does not replace it" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("A").shutdown = .fails;
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    rig.end("Waiter", error.Unavailable);
    try testing.expectError(error.Unavailable, app.wait());
    try expectFailure(&app, "Root.Waiter", .wait, error.Unavailable);
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
}

test "a bean's own ShutdownTimeout is fatal" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.C }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("B").shutdown = .times_out;
    // App frees no bean after it: the arena takes the block back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var app = try zapp.App(Root).init(arena.allocator(), testing.io, .{&rig}, .{});
    try app.start();
    app.requestStop();
    try testing.expectError(error.ShutdownTimeout, app.wait());
    try testing.expectEqual(zapp.State.failed, app.state());
    try expectFailure(&app, "Root.B", .shutdown, error.ShutdownTimeout);
    try rig.expectUnordered("shutdown", &.{ "A", "B", "C" });
    // It takes back the ended stop task, so testing.allocator sees no leak.
    app.deinit();
    try rig.expect("deinit", &.{});
    try testing.expect(app.internal.block.runtime.stop_task == null);
}

test "a breakdown does not hide a ShutdownTimeout" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.B, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("B").shutdown = .times_out;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var app = try zapp.App(Root).init(arena.allocator(), testing.io, .{&rig}, .{});
    try app.start();
    rig.end("Waiter", error.Unavailable);
    try testing.expectError(error.ShutdownTimeout, app.wait());
    try expectFailure(&app, "Root.Waiter", .wait, error.Unavailable);
    app.deinit();
    try rig.expect("deinit", &.{});
}

test "a breakdown does not hide a shutdown that runs out of time" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.B, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, budget(50));
    {
        // Only up to the last deinit: it frees the block, which settle reads.
        errdefer settle(&app, &rig);
        try app.start();
        rig.end("Waiter", error.Unavailable);
        try testing.expectError(error.ShutdownTimeout, app.wait());
        try expectFailure(&app, "Root.Waiter", .wait, error.Unavailable);
        app.deinit();
        try rig.expect("deinit", &.{});
        rig.open("B");
        try awaitEnded(&app);
    }
    app.deinit();
    try rig.expect("deinit", &.{ "Waiter", "B" });
}

test "a deaf shutdown: wait returns ShutdownTimeout at the deadline; deinit frees nothing until the stop ends" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.B }, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, budget(50));
    {
        // Only up to the last deinit: it frees the block, which settle reads.
        errdefer settle(&app, &rig);
        try app.start();
        const asked = Io.Clock.awake.now(io);
        app.requestStop();
        try testing.expectError(error.ShutdownTimeout, app.wait());
        const took = asked.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
        try testing.expect(took >= 50 - 16 and took < 2000);
        try testing.expectEqual(zapp.State.failed, app.state());
        try expectFailure(&app, "Root.B", .shutdown, error.ShutdownTimeout);
        // Every later wait returns the same.
        try testing.expectError(error.ShutdownTimeout, app.wait());
        app.deinit();
        try rig.expect("deinit", &.{});
        rig.open("B");
        try awaitEnded(&app);
        // The stop went on: First got its shutdown once B's returned.
        try rig.expect("shutdown", &.{ "B", "First" });
    }
    app.deinit();
    try rig.expect("deinit", &.{ "B", "First" });
}

test "the stop shuts the servers down together, then the others one at a time, last created first" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.A, gates.Second, gates.B }, .values = &.{*Rig} };
    };
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("A").shutdown = .deaf;
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    {
        errdefer {
            settle(&app, &rig);
            app.deinit();
        }
        try app.start();
        app.requestStop();
        // Both servers are in their shutdown at once, with the deadline of
        // the start of the stop; the clients wait for them.
        try rig.entered("A");
        try rig.entered("B");
        try testing.expect(rig.position("shutdown", "Second") == null and rig.position("shutdown", "First") == null);
        rig.open("A");
        rig.open("B");
        try app.wait();
        try testing.expect(app.failure() == null);
        try testing.expectEqual(rig.of("A").deadline.?, rig.of("B").deadline.?);
    }
    app.deinit();
    try rig.expect("requestStop", &.{ "A", "B" });
    // The clients once both servers had returned, Second, built later, first.
    const second = rig.position("shutdown", "Second").?;
    try testing.expect(second > rig.position("shut", "A").? and second > rig.position("shut", "B").?);
    try testing.expect(rig.position("shutdown", "First").? > rig.position("shut", "Second").?);
    try rig.expect("deinit", &.{ "B", "Second", "A", "First" });
}

test "two servers whose shutdowns fail: the error recorded first is the cause" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B }, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    {
        var rig: Rig = .init(io);
        defer rig.release();
        rig.of("A").shutdown = .fails;
        rig.of("B").shutdown = .fails_late;
        var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
        {
            errdefer {
                settle(&app, &rig);
                app.deinit();
            }
            try app.start();
            app.requestStop();
            // B, built last, is still in its shutdown when A's fails.
            try rig.entered("B");
            try awaitFailure(&app);
            try expectFailure(&app, "Root.A", .shutdown, error.ShutdownFailed);
            // B's fails after it, and the first cause stays.
            rig.open("B");
            try testing.expectError(error.ShutdownFailed, app.wait());
            try expectFailure(&app, "Root.A", .shutdown, error.ShutdownFailed);
            try testing.expectEqual(zapp.State.stopped, app.state());
        }
        app.deinit();
    }
    // Both fail at the same time: one of them is the cause.
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("A").shutdown = .fails;
    rig.of("B").shutdown = .fails;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    try testing.expectError(error.ShutdownFailed, app.shutdown());
    const failure = app.failure() orelse return error.TestExpectedFailure;
    try testing.expect(std.mem.eql(u8, failure.bean, "Root.A") or std.mem.eql(u8, failure.bean, "Root.B"));
    try testing.expectEqual(zapp.Failure.Step.shutdown, failure.step);
    try testing.expectEqual(error.ShutdownFailed, failure.err);
    try rig.expectUnordered("shutdown", &.{ "A", "B" });
}

test "a deaf server: the other servers still stop, wait returns ShutdownTimeout at the deadline, deinit frees nothing" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.A, gates.B }, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, budget(50));
    {
        errdefer {
            settle(&app, &rig);
            app.deinit();
        }
        try app.start();
        const asked = Io.Clock.awake.now(io);
        app.requestStop();
        try testing.expectError(error.ShutdownTimeout, app.wait());
        const took = asked.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
        try testing.expect(took >= 50 - 16 and took < 2000);
        try testing.expectEqual(zapp.State.failed, app.state());
        try expectFailure(&app, "Root.B", .shutdown, error.ShutdownTimeout);
        // A, the other server, stopped beside B; First, a client, waits for B.
        try awaitEvent(&rig, "shut", "A");
        try testing.expect(rig.position("shutdown", "First") == null);
        app.deinit();
        try rig.expect("deinit", &.{});
        rig.open("B");
        try awaitEnded(&app);
        try testing.expect(rig.position("shutdown", "First").? > rig.position("shut", "B").?);
    }
    app.deinit();
    try rig.expect("deinit", &.{ "B", "A", "First" });
}

test "no task for a server's shutdown: the stop task shuts it down itself, beside the others" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.First, gates.A, gates.B }, .values = &.{*Rig} };
    };
    // The stop task takes one task, and B's shutdown, asked first as B was
    // built last, the other: A's shutdown gets none.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, .{});
    {
        errdefer {
            settle(&app, &rig);
            app.deinit();
        }
        try app.start();
        app.requestStop();
        try rig.entered("B");
        // A's shutdown runs in the stop task while B's holds a task of its own.
        try awaitEvent(&rig, "shut", "A");
        try testing.expect(rig.position("shutdown", "First") == null);
        rig.open("B");
        try app.wait();
        try testing.expect(app.failure() == null);
    }
    app.deinit();
    try testing.expect(rig.position("shutdown", "First").? > rig.position("shut", "B").?);
    try rig.expect("deinit", &.{ "B", "A", "First" });
}

test "requestStop many times from many tasks: one stop" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B, gates.Waiter }, .values = &.{*Rig} };
    };
    const App = zapp.App(Root);
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try App.init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |_| try group.concurrent(io, Calls(App).requestStop, .{&app});
    // And a bean breaks meanwhile.
    rig.end("Waiter", error.Unavailable);
    try group.await(io);
    if (app.wait()) |_| {} else |err| try testing.expectEqual(error.Unavailable, err);
    if (app.failure()) |failure| try testing.expectEqualStrings("Root.Waiter", failure.bean);
    try rig.expect("requestStop", &.{ "A", "B", "Waiter" });
    try rig.expectUnordered("shutdown", &.{ "A", "B", "Waiter" });
    try testing.expectEqual(zapp.State.stopped, app.state());
}

test "requestStop before start: stopped, start is InvalidState, wait returns {}" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    {
        errdefer app.deinit();
        app.requestStop();
        try testing.expectEqual(zapp.State.stopped, app.state());
        try testing.expectError(error.InvalidState, app.start());
        try app.wait();
        try app.shutdown();
        try testing.expect(app.failure() == null);
    }
    app.deinit();
    try rig.expect("start", &.{});
    try rig.expect("shutdown", &.{});
    try rig.expect("deinit", &.{ "Waiter", "A" });
}

test "wait before start is InvalidState" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{gates.A}, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try testing.expectError(error.InvalidState, app.wait());
    try testing.expectEqual(zapp.State.created, app.state());
}

test "no restart: start after the stop is InvalidState" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    try testing.expectError(error.InvalidState, app.start());
    try app.shutdown();
    try testing.expectError(error.InvalidState, app.start());
    try rig.expect("start", &.{ "A", "B" });
    // Nor after a start that failed.
    var failed_rig: Rig = .init(testing.io);
    defer failed_rig.release();
    failed_rig.of("B").start = .fails;
    var failed = try zapp.App(Root).init(testing.allocator, testing.io, .{&failed_rig}, .{});
    defer failed.deinit();
    try testing.expectError(error.StartFailed, failed.start());
    try testing.expectError(error.InvalidState, failed.start());
}

test "wait after the end returns the same result again" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    rig.end("Waiter", error.Unavailable);
    try testing.expectError(error.Unavailable, app.wait());
    try testing.expectError(error.Unavailable, app.wait());
    try testing.expectError(error.Unavailable, app.shutdown());
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
}

test "canceling wait does not stop the App" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    const App = zapp.App(Root);
    const io = testing.io;
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try App.init(testing.allocator, io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    var waiting = try io.concurrent(Calls(App).wait, .{&app});
    defer waiting.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
    try testing.expectEqual(zapp.State.running, app.state());
    try rig.expect("requestStop", &.{});
    try app.shutdown();
    try testing.expectEqual(zapp.State.stopped, app.state());
}

test "shutdown is requestStop and wait" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    defer app.deinit();
    try app.start();
    try app.shutdown();
    try testing.expectEqual(zapp.State.stopped, app.state());
    try rig.expect("requestStop", &.{ "A", "Waiter" });
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
    // A second one stops nothing more.
    try app.shutdown();
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
}

test "deinit while running stops the App first" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter, gates.C }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try app.start();
    }
    app.deinit();
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter", "C" });
    try rig.expect("deinit", &.{ "C", "Waiter", "A" });
    try testing.expect(rig.position("shutdown", "A").? < rig.position("deinit", "C").?);
}

test "deinit without start starts nothing and destroys in reverse" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter, gates.C }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    app.deinit();
    try rig.expect("start", &.{});
    try rig.expect("requestStop", &.{});
    try rig.expect("shutdown", &.{});
    try rig.expect("deinit", &.{ "C", "Waiter", "A" });
}

/// A ready object whose type has lifecycle methods: App never calls them.
const Tool = struct {
    rig: *Rig,

    pub fn start(t: *Tool, _: Io) !void {
        t.rig.rec.add("start", "Tool");
    }
    pub fn deinit(t: *Tool) void {
        t.rig.rec.add("deinit", "Tool");
    }
};

test "values, controllers and handlers are never driven" {
    const User = struct { tool: *Tool };
    const Panel = struct {
        tool: *Tool,

        pub const http_routes = .{"GET /panel"};
    };
    const Ops = struct {
        pub const rpc_handler = .{ .api = "ops.v1" };
    };
    const Root = struct {
        pub const module: zapp.Module = .{
            .providers = &.{ User, gates.A },
            .controllers = &.{Panel},
            .handlers = &.{Ops},
            .values = &.{ *Tool, *Rig },
        };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var tool: Tool = .{ .rig = &rig };
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{ &tool, &rig }, .{});
    {
        errdefer app.deinit();
        try testing.expectEqual(1, app.internal.block.entries.len);
        try app.start();
        try app.shutdown();
    }
    app.deinit();
    try rig.expect("start", &.{"A"});
    try rig.expect("deinit", &.{"A"});
}

test "Status: ready only while running and every bean is ready" {
    const Probe = struct {
        status: *const zapp.Status,
        ready: std.atomic.Value(bool) = .init(true),
        ready_in_request_stop: std.atomic.Value(bool) = .init(true),

        pub fn requestStop(p: *@This(), _: Io) void {
            p.ready_in_request_stop.store(p.status.isReady(), .release);
        }
        pub fn isReady(p: *const @This()) bool {
            return p.ready.load(.acquire);
        }
    };
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{Probe} };
    };
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{}, .{});
    defer app.deinit();
    const probe = app.get(Probe);
    try testing.expect(!probe.status.isReady());
    try app.start();
    try testing.expect(probe.status.isReady() and app.isReady());
    probe.ready.store(false, .release);
    try testing.expect(!probe.status.isReady() and !app.isReady());
    probe.ready.store(true, .release);
    try testing.expect(probe.status.isReady());
    try app.shutdown();
    // The first step of the stop took readiness away.
    try testing.expect(!probe.ready_in_request_stop.load(.acquire));
    try testing.expect(!probe.status.isReady() and !app.isReady());
}

test "the watchers end before the beans are destroyed" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Stubborn }, .values = &.{*Rig} };
    };
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, testing.io, .{&rig}, .{});
    {
        errdefer app.deinit();
        try app.start();
        // Its own shutdown does not end its wait: the gathering cancels it.
        try app.shutdown();
        try testing.expect(rig.position("shutdown", "A").? < rig.position("waited", "Stubborn").?);
    }
    app.deinit();
    try testing.expect(rig.position("waited", "Stubborn").? < rig.position("deinit", "Stubborn").?);
}

const Moved = struct {
    pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Waiter }, .values = &.{*Rig} };
};

/// Returns the App by value: it moves, its block does not.
fn makeMoved(rig: *Rig) !zapp.App(Moved) {
    return zapp.App(Moved).init(testing.allocator, rig.io, .{rig}, .{});
}

test "an App returned from a helper starts and stops" {
    var rig: Rig = .init(testing.io);
    defer rig.release();
    var first = try makeMoved(&rig);
    const waiter = first.get(gates.Waiter);
    const status = &first.internal.block.status;
    // Moved once more, into a struct, before the start.
    var holder: struct { before: u64 = 1, app: zapp.App(Moved) } = .{ .app = first };
    first = undefined;
    const app = &holder.app;
    {
        errdefer app.deinit();
        try testing.expect(app.get(gates.Waiter) == waiter);
        try app.start();
        try testing.expect(status.state() == .running);
        try app.shutdown();
        try testing.expect(status.state() == .stopped);
    }
    app.deinit();
    try rig.expect("start", &.{ "A", "Waiter" });
    try rig.expectUnordered("shutdown", &.{ "A", "Waiter" });
    try rig.expect("deinit", &.{ "Waiter", "A" });
}
