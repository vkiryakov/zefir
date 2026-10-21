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
    try rig.expect("shutdown", &.{ "Waiter", "B", "A" });
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
    try rig.expect("shutdown", &.{ "Waiter", "A" });
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
    try rig.expect("shutdown", &.{ "Waiter", "A" });
    // A second one stops nothing more.
    try app.shutdown();
    try rig.expect("shutdown", &.{ "Waiter", "A" });
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
    try rig.expect("shutdown", &.{ "C", "Waiter", "A" });
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
    try rig.expect("shutdown", &.{ "Waiter", "A" });
    try rig.expect("deinit", &.{ "Waiter", "A" });
}
