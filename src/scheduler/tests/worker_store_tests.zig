//! Tests of scheduler.Worker while its store fails: no run without a
//! claim, the pauses of the poll, a claim whose reply is lost, a finish
//! sent again until the store takes it, and `wait`, which never returns
//! an error of the store.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const fixture = @import("worker_fixture.zig");
const Fixture = fixture.Fixture;
const Probe = fixture.Probe;
const Job = fixture.Job;
const io = fixture.io;
const quick = fixture.quick;
const reach = fixture.reach;
const nowMs = fixture.nowMs;

const Lossy = Job(.{ .name = "lossy", .history = .forever, .when_done = .{ .succeeded = .forever } });

/// Waits until the worker counted `n` errors of its store.
fn errors(w: anytype, n: u64) !void {
    const give_up = nowMs() + 5000;
    while (w.stats().store_errors < n) {
        if (nowMs() >= give_up) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "while claims fail no job runs, store_down shows it and the poll backs off" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Lossy = .{ .probe = &probe };
    try f.schedule(Lossy, "x", .{ .after = .zero });
    f.faulty.failNext(io, .claim, error.Unavailable, 5);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var options = quick;
    options.max_backoff = .fromMilliseconds(400);
    var w: scheduler.Worker(struct { job: *Lossy }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    const began = nowMs();
    try w.start(io);
    try errors(&w, 2);
    try testing.expect(w.stats().store_down);
    try testing.expectEqual(@as(u32, 0), probe.runs.load(.acquire));
    try reach(&probe.runs, 1, 10);
    // Pauses of 200 ms, then 400 ms, less 10 %: far slower than a claim
    // every 100 ms.
    try testing.expect(nowMs() - began >= 1000);
    _ = try f.until(.of(Lossy, "x"), .succeeded, 5);
    try testing.expect(!w.stats().store_down);
    try testing.expectEqual(@as(u64, 5), w.stats().store_errors);
}

test "a claim whose reply is lost runs nothing, and the job comes back after its lease" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Lossy = .{ .probe = &probe };
    try f.schedule(Lossy, "x", .{ .after = .zero });
    f.faulty.loseNextReply(io, .claim);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Lossy }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    try io.sleep(.fromMilliseconds(1500), .awake);
    try testing.expectEqual(@as(u32, 0), probe.runs.load(.acquire));
    const r = (try f.until(.of(Lossy, "x"), .succeeded, 8)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), probe.runs.load(.acquire));
    try testing.expectEqual(@as(u32, 2), probe.attempt.load(.acquire));
    try testing.expectEqual(@as(u64, 2), r.fence);
    const rows = try f.rows(.of(Lossy, "x"));
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(scheduler.RunOutcome.succeeded, rows[0].outcome);
    try testing.expectEqual(scheduler.RunOutcome.abandoned, rows[1].outcome);
    try testing.expectEqual(@as(u64, 1), w.stats().taken_over);
}

test "a finish that fails is repeated until it goes through" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Lossy = .{ .probe = &probe };
    try f.schedule(Lossy, "x", .{ .after = .zero });
    f.faulty.failNext(io, .finish, error.Unavailable, 3);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Lossy }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    const r = (try f.until(.of(Lossy, "x"), .succeeded, 8)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1), r.fence);
    try testing.expectEqual(@as(u32, 1), probe.runs.load(.acquire));
    try testing.expectEqual(@as(usize, 1), (try f.rows(.of(Lossy, "x"))).len);
    try testing.expectEqual(@as(u64, 3), w.stats().store_errors);
    // Three failed before the store; the fourth reached it.
    try testing.expectEqual(@as(u32, 1), f.faulty.calls(io, .finish));
}

const Timed = Job(.{ .name = "timed", .timeout = .fromSeconds(2), .retry = .{ .attempts = 1 } });

/// A run held 10 s whose first renewal, a second after its claim, hangs
/// until its deadline; the lease of 30 s leaves the renewal its whole
/// `store_timeout`, 5 s, unless the timeout of the job or the end of the
/// grace of a stop comes first.
fn renewalHangs(cut: enum { timeout, grace }) !void {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var lossy: Lossy = .{ .probe = &probe };
    var timed: Timed = .{ .probe = &probe };
    switch (cut) {
        .timeout => try f.schedule(Timed, "x", .{ .after = .zero }),
        .grace => try f.schedule(Lossy, "x", .{ .after = .zero }),
    }
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var options = quick;
    options.lease = .fromSeconds(30);
    options.shutdown_grace = .fromMilliseconds(1500);
    var w: scheduler.Worker(struct { lossy: *Lossy, timed: *Timed }) = try .init(testing.allocator, io, f.store(), .{ .lossy = &lossy, .timed = &timed }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    f.faulty.stallNext(io, .renew, .fromSeconds(10));
    if (cut == .grace) w.requestStop(io);
    try reach(&probe.ended, 1, 10);
    // Cancelled at 2 s or 1.5 s, not once the renewal gave up at 6 s.
    try testing.expectEqual(@as(u32, 1), probe.cancelled.load(.acquire));
    try testing.expect(probe.stopped.load(.acquire) - probe.started.load(.acquire) < 4000);
}

test "a renewal that hangs ends at the timeout of its run or at the end of the grace" {
    try renewalHangs(.timeout);
    try renewalHangs(.grace);
}

test "wait returns no store errors" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Lossy = .{ .probe = &probe };
    f.faulty.failNext(io, .claim, error.Unavailable, 1000);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Lossy }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    try errors(&w, 2);
    try testing.expect(w.isReady());
    w.requestStop(io);
    try w.wait(io);
    try testing.expectEqual(scheduler.Worker(struct { job: *Lossy }).State.stopped, w.state());
}
