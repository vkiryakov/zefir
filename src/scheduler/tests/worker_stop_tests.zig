//! Tests of the stop of scheduler.Worker: the jobs claimed and not
//! started go back at once, the runs get the grace, then are cancelled and
//! given back; the deadline of `shutdown` cuts the grace, and a handler
//! that ignores its cancel makes `shutdown` give up 250 ms before it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const scheduler = @import("../root.zig");
const fixture = @import("worker_fixture.zig");
const Fixture = fixture.Fixture;
const Probe = fixture.Probe;
const Job = fixture.Job;
const io = fixture.io;
const quick = fixture.quick;
const reach = fixture.reach;
const nowMs = fixture.nowMs;

const Held = Job(.{ .name = "held", .history = .forever, .when_done = .{ .succeeded = .forever } });
const Queued = Job(.{ .name = "queued", .history = .forever });
const Worker = scheduler.Worker(struct { held: *Held });

/// The moment `ms` from now on the awake clock.
fn fromNow(ms: i64) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(ms), .clock = .awake });
}

/// Milliseconds from `deadline` to now: negative before it.
fn msPast(deadline: Io.Clock.Timestamp) i64 {
    return nowMs() - deadline.raw.toMilliseconds();
}

/// The state of the record of `ref`, null when there is none.
fn stateOf(f: *Fixture, ref: scheduler.Ref) !?scheduler.State {
    const r = (try f.get(ref)) orelse return null;
    return r.state;
}

/// The record of `ref` given back by a stop: pending again, the attempt
/// not counted.
fn expectBack(f: *Fixture, ref: scheduler.Ref) !void {
    const r = (try f.get(ref)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(@as(u64, 1), r.fence);
}

test "requestStop returns jobs claimed and not started, and lets runs end within the grace" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromMilliseconds(800) };
    var queued_probe: Probe = .{};
    var held: Held = .{ .probe = &probe };
    var queued: Queued = .{ .probe = &queued_probe };
    try f.schedule(Held, "r", .{ .after = .zero });
    var options = quick;
    options.workers = 3;
    var w: scheduler.Worker(struct { held: *Held, queued: *Queued }) = try .init(testing.allocator, io, f.store(), .{ .held = &held, .queued = &queued }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    // The next claim hangs for 2 s, the stop comes meanwhile, and the
    // claim takes two jobs after it.
    f.faulty.stallNext(io, .claim, .fromSeconds(2));
    try f.schedule(Queued, "a", .{ .after = .zero });
    try f.schedule(Queued, "b", .{ .after = .zero });
    try io.sleep(.fromMilliseconds(500), .awake);
    w.requestStop(io);
    try w.wait(io);
    try testing.expectEqual(@as(?scheduler.State, .succeeded), try stateOf(&f, .of(Held, "r")));
    try testing.expectEqual(@as(u32, 0), probe.cancelled.load(.acquire));
    for ([_][]const u8{ "a", "b" }) |key| {
        try expectBack(&f, .of(Queued, key));
        const r = (try f.get(.of(Queued, key))) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(null, r.last);
        try testing.expectEqual(@as(usize, 0), (try f.rows(.of(Queued, key))).len);
    }
    try testing.expectEqual(@as(u32, 0), queued_probe.runs.load(.acquire));
}

test "at the end of the grace runs are cancelled and their jobs returned" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var held: Held = .{ .probe = &probe };
    try f.schedule(Held, "x", .{ .after = .zero });
    var options = quick;
    options.shutdown_grace = .fromMilliseconds(500);
    var w: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const began = nowMs();
    w.requestStop(io);
    try w.wait(io);
    const took = nowMs() - began;
    try testing.expect(took >= 450 and took < 3000);
    try testing.expectEqual(@as(u32, 1), probe.cancelled.load(.acquire));
    try expectBack(&f, .of(Held, "x"));
    const rows = try f.rows(.of(Held, "x"));
    if (rows.len != 1) return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.interrupted, rows[0].outcome);
    try testing.expectEqualDeep(@as(?[]const u8, "Shutdown"), rows[0].error_name);
}

test "a handler that never yields makes shutdown return ShutdownTimeout" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    probe.deaf.store(true, .release);
    var held: Held = .{ .probe = &probe };
    try f.schedule(Held, "x", .{ .after = .zero });
    var options = quick;
    options.shutdown_grace = .fromMilliseconds(500);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, options);
    defer w.deinit(io);
    // Before the deinit: the handler ends once the flag drops.
    defer probe.deaf.store(false, .release);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const deadline = fromNow(3000);
    try testing.expectError(error.ShutdownTimeout, w.shutdown(io, deadline));
    try testing.expect(msPast(deadline) >= -260 and msPast(deadline) <= -50);
    try testing.expectEqual(@as(u32, 1), probe.cancelled.load(.acquire));
    try testing.expectEqual(Worker.State.draining, w.state());
}

test "a deadline closer than the grace cancels at once" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var held: Held = .{ .probe = &probe };
    try f.schedule(Held, "x", .{ .after = .zero });
    var w: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const deadline = fromNow(1000);
    try w.shutdown(io, deadline);
    try testing.expect(msPast(deadline) <= -250);
    try testing.expectEqual(Worker.State.stopped, w.state());
    try expectBack(&f, .of(Held, "x"));

    // A deadline already past: shutdown returns at once.
    try f.schedule(Held, "y", .{ .after = .zero });
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var late: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, quick);
    defer late.deinit(io);
    try late.start(io);
    try reach(&probe.runs, 3, 5);
    const began = nowMs();
    late.shutdown(io, fromNow(-1000)) catch |err| try testing.expectEqual(error.ShutdownTimeout, err);
    try testing.expect(nowMs() - began < 500);
}

test "requestStop twice does nothing and wait returns after the stop" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromMilliseconds(300) };
    var held: Held = .{ .probe = &probe };
    try f.schedule(Held, "x", .{ .after = .zero });
    var w: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    w.requestStop(io);
    w.requestStop(io);
    try testing.expectEqual(Worker.State.draining, w.state());
    try testing.expect(!w.isReady());
    try w.wait(io);
    try testing.expectEqual(Worker.State.stopped, w.state());
    try testing.expectEqual(@as(u32, 1), probe.ended.load(.acquire));
    try testing.expectEqual(@as(u32, 0), probe.cancelled.load(.acquire));
    try testing.expectEqual(@as(?scheduler.State, .succeeded), try stateOf(&f, .of(Held, "x")));
}

test "deinit of a running worker stops it and waits" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var held: Held = .{ .probe = &probe };
    try f.schedule(Held, "x", .{ .after = .zero });
    var options = quick;
    options.shutdown_grace = .fromMilliseconds(300);
    var w: Worker = try .init(testing.allocator, io, f.store(), .{ .held = &held }, options);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const began = nowMs();
    w.deinit(io);
    try testing.expect(nowMs() - began < 3000);
    try testing.expectEqual(@as(u32, 1), probe.ended.load(.acquire));
    try expectBack(&f, .of(Held, "x"));
}
