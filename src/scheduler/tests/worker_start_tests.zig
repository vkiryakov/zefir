//! Tests of the start of scheduler.Worker and of its poll: the records of
//! declared jobs, the runs of one-shot and repeating jobs, the slots, and
//! the moment the store says the next job is due.

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

const Plain = Job(.{ .name = "plain" });
const Kept = Job(.{ .name = "kept", .when_done = .{ .succeeded = .forever } });

test "a one-shot job runs once and its record goes as when_done says" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var plain_probe: Probe = .{};
    var kept_probe: Probe = .{};
    var plain: Plain = .{ .probe = &plain_probe };
    var kept: Kept = .{ .probe = &kept_probe };
    try f.schedule(Plain, "a", .{ .after = .zero });
    try f.schedule(Kept, "b", .{ .after = .zero });
    var w: scheduler.Worker(struct { plain: *Plain, kept: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain, .kept = &kept }, quick);
    defer w.deinit(io);
    try w.start(io);
    try testing.expect(w.isReady());
    try testing.expectEqual(null, try f.until(.of(Plain, "a"), null, 5));
    const done = (try f.until(.of(Kept, "b"), .succeeded, 5)) orelse return error.TestUnexpectedResult;
    const last = done.last orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.succeeded, last.outcome);
    try testing.expectEqual(@as(u32, 1), last.attempt);
    try io.sleep(.fromMilliseconds(300), .awake);
    try testing.expectEqual(@as(u32, 1), plain_probe.runs.load(.acquire));
    try testing.expectEqual(@as(u32, 1), kept_probe.runs.load(.acquire));
    const s = w.stats();
    try testing.expectEqual(@as(u64, 2), s.claimed);
    try testing.expectEqual(@as(u64, 2), s.succeeded);
}

test "a recurring job runs again at its next moment" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var plain: Plain = .{ .probe = &probe };
    try f.schedule(Plain, "tick", .{ .repeat = .everySeconds(1) });
    var w: scheduler.Worker(struct { plain: *Plain }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.ended, 2, 6);
    const r = (try f.get(.of(Plain, "tick"))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("every 1s", r.plan);
    try testing.expect(r.fence >= 2);
}

const Pulse = Job(.{ .name = "pulse", .repeat = .everySeconds(1) });
const PulseEvery2 = Job(.{ .name = "pulse", .repeat = .everySeconds(2) });
const PulseKeyed = Job(.{ .name = "pulse" });
const Hourly = Job(.{ .name = "hourly", .repeat = .everyHours(1) });

test "start writes declared jobs, fixes a changed plan and leaves parked ones alone" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var pulse: Pulse = .{ .probe = &probe };
    var w1: scheduler.Worker(struct { pulse: *Pulse }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &pulse }, quick);
    try w1.start(io);
    w1.deinit(io);
    const first = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("every 1s", first.plan);
    try testing.expectEqualStrings("{\"n\":0}", first.payload);

    // A version with another plan moves the record to it.
    var every2: PulseEvery2 = .{ .probe = &probe };
    var w2: scheduler.Worker(struct { pulse: *PulseEvery2 }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &every2 }, quick);
    try w2.start(io);
    w2.deinit(io);
    const moved = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("every 2s", moved.plan);
    try testing.expectEqualSlices(u8, &first.life, &moved.life);

    // A version that knows the job without .repeat, and declares another
    // one, finds the record parked: it warns and never claims it. The
    // other declaration runs at a full hour, which may come during the test.
    var keyed_probe: Probe = .{};
    var hourly_probe: Probe = .{};
    var keyed: PulseKeyed = .{ .probe = &keyed_probe };
    var hourly: Hourly = .{ .probe = &hourly_probe };
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w3: scheduler.Worker(struct { pulse: *PulseKeyed, hourly: *Hourly }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &keyed, .hourly = &hourly }, quick);
    try w3.start(io);
    try testing.expectEqual(@as(u32, 1), w3.stats().undeclared);
    const parked = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    try io.sleep(.fromMilliseconds(2500), .awake);
    w3.deinit(io);
    try testing.expectEqual(@as(u32, 0), keyed_probe.runs.load(.acquire));
    const still = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.pending, still.state);
    try testing.expectEqual(parked.fence, still.fence);

    // Its explicit removal, and a version that declares it again runs it.
    try testing.expect(try f.client.cancel(io, .root, .declared(PulseKeyed), .{}));
    try testing.expectEqual(null, try f.get(.declared(Pulse)));
    const before = probe.ended.load(.acquire);
    var w4: scheduler.Worker(struct { pulse: *Pulse }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &pulse }, quick);
    defer w4.deinit(io);
    try w4.start(io);
    try reach(&probe.ended, before + 1, 5);
}

test "after a lost reply of the create of a declared job, start reads the record and goes on" {
    // A store may answer OutcomeUnknown for a create due soon, as a
    // declared job of a short period is (rule 7 of the contract). A run
    // never deletes a declared record, and a create meets a live one as
    // existing: start reads the record, and creates it again only when
    // there is none.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    for ([_]bool{ false, true }) |applied| {
        var f: Fixture = undefined;
        f.init();
        defer f.deinit();
        var probe: Probe = .{};
        var pulse: Pulse = .{ .probe = &probe };
        // The create made the record, or never reached the store.
        if (applied) f.faulty.loseNextReply(io, .create) else f.faulty.failNext(io, .create, error.OutcomeUnknown, 1);
        var w: scheduler.Worker(struct { pulse: *Pulse }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &pulse }, quick);
        defer w.deinit(io);
        try w.start(io);
        const r = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("every 1s", r.plan);
        // One create reached the store: the first, or the one after it.
        try testing.expectEqual(@as(u32, 1), f.faulty.calls(io, .create));
    }

    // A record there before, of another life: start goes on as after
    // `existing`, and the record takes the plan of the code.
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var pulse: Pulse = .{ .probe = &probe };
    var w1: scheduler.Worker(struct { pulse: *Pulse }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &pulse }, quick);
    try w1.start(io);
    w1.deinit(io);
    const before = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    f.faulty.failNext(io, .create, error.OutcomeUnknown, 1);
    var every2: PulseEvery2 = .{ .probe = &probe };
    var w2: scheduler.Worker(struct { pulse: *PulseEvery2 }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &every2 }, quick);
    defer w2.deinit(io);
    try w2.start(io);
    const moved = (try f.get(.declared(Pulse))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("every 2s", moved.plan);
    try testing.expectEqualSlices(u8, &before.life, &moved.life);
    try testing.expectEqual(@as(u32, 1), f.faulty.calls(io, .create));
}

test "a worker without declared jobs does not touch the store at start" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var plain: Plain = .{ .probe = &probe };
    var w: scheduler.Worker(struct { plain: *Plain }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain }, quick);
    defer w.deinit(io);
    try w.start(io);
    for ([_]scheduler.testing.Op{ .create, .get, .update }) |op| try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, op));
}

test "no more than workers runs at once" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromMilliseconds(50) };
    var plain: Plain = .{ .probe = &probe };
    for (0..20) |i| {
        var key: [8]u8 = undefined;
        try f.schedule(Plain, try std.fmt.bufPrint(&key, "k{d}", .{i}), .{ .after = .zero });
    }
    var options = quick;
    options.workers = 3;
    var w: scheduler.Worker(struct { plain: *Plain }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.ended, 20, 10);
    try testing.expectEqual(@as(u32, 3), probe.most.load(.acquire));
    try testing.expectEqual(@as(u32, 20), probe.runs.load(.acquire));
}

test "next_in wakes the poll early" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var plain: Plain = .{ .probe = &probe };
    try f.schedule(Plain, "soon", .{ .after = .fromMilliseconds(300) });
    var options = quick;
    options.poll_every = .fromSeconds(10);
    var w: scheduler.Worker(struct { plain: *Plain }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
}

test "start twice is InvalidState; a store that fails at start gives its error" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var pulse: Pulse = .{ .probe = &probe };
    f.faulty.failNext(io, .create, error.Unavailable, 1);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var failed: scheduler.Worker(struct { pulse: *Pulse }) = try .init(testing.allocator, io, f.store(), .{ .pulse = &pulse }, quick);
    defer failed.deinit(io);
    try testing.expectError(error.Unavailable, failed.start(io));
    try testing.expectEqual(scheduler.Worker(struct { pulse: *Pulse }).State.stopped, failed.state());
    try testing.expectError(error.InvalidState, failed.start(io));
    try failed.wait(io);

    var plain: Plain = .{ .probe = &probe };
    var w: scheduler.Worker(struct { plain: *Plain }) = try .init(testing.allocator, io, f.store(), .{ .plain = &plain }, quick);
    defer w.deinit(io);
    try w.start(io);
    try testing.expectError(error.InvalidState, w.start(io));
    try testing.expectEqual(scheduler.Worker(struct { plain: *Plain }).State.running, w.state());
}
