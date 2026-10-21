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
    try rig.expect("shutdown", &.{ "B", "Waiter", "A" });
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
    try rig.expect("shutdown", &.{ "Waiter", "A" });
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
    var rig: Rig = .init(io);
    defer rig.release();
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, budget(50));
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
    rig.open("DeafWait");
    try awaitEnded(&app);
    app.deinit();
    try rig.expect("deinit", &.{"DeafWait"});
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
    const after = asked.addDuration(.fromSeconds(5)).durationTo(deadline.raw).toMilliseconds();
    try testing.expect(after >= 0 and after < 50);
}

test "a bean with wait and no shutdown: App waits for its wait" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.Lingering }, .values = &.{*Rig} };
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
    // Its wait returned before App went on to the beans created before it.
    try testing.expect(rig.position("waited", "Lingering").? < rig.position("shutdown", "A").?);
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
    try rig.expect("shutdown", &.{ "C", "B", "A" });
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
    try rig.expect("shutdown", &.{ "Waiter", "A" });
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
    try rig.expect("shutdown", &.{ "C", "B", "A" });
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
    try app.start();
    rig.end("Waiter", error.Unavailable);
    try testing.expectError(error.ShutdownTimeout, app.wait());
    try expectFailure(&app, "Root.Waiter", .wait, error.Unavailable);
    app.deinit();
    try rig.expect("deinit", &.{});
    rig.open("B");
    try awaitEnded(&app);
    app.deinit();
    try rig.expect("deinit", &.{ "Waiter", "B" });
}

test "a deaf shutdown: wait returns ShutdownTimeout at the deadline; deinit frees nothing until the stop ends" {
    const Root = struct {
        pub const module: zapp.Module = .{ .providers = &.{ gates.A, gates.B }, .values = &.{*Rig} };
    };
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var rig: Rig = .init(io);
    defer rig.release();
    rig.of("B").shutdown = .deaf;
    var app = try zapp.App(Root).init(testing.allocator, io, .{&rig}, budget(50));
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
    // The stop went on: A got its shutdown once B's returned.
    try rig.expect("shutdown", &.{ "B", "A" });
    app.deinit();
    try rig.expect("deinit", &.{ "B", "A" });
}
