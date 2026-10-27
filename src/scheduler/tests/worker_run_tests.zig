//! Tests of a run of scheduler.Worker: retries, the timeout, the renewals
//! of its lease (unconfirmed, taken over, removed), the misfires of a
//! repeating job, abandoned attempts, payloads that do not read, and the
//! counters.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const fixture = @import("worker_fixture.zig");
const Fixture = fixture.Fixture;
const Probe = fixture.Probe;
const Job = fixture.Job;
const Store = scheduler.Store;
const io = fixture.io;
const quick = fixture.quick;
const reach = fixture.reach;
const nowMs = fixture.nowMs;

const Kept = Job(.{ .name = "kept", .retry = .{ .attempts = 1 }, .history = .forever });
const Failing = Job(.{ .name = "failing", .retry = .{ .attempts = 3, .delay = .fromMilliseconds(300), .multiplier = 1 } });
const Slow = Job(.{ .name = "slow", .timeout = .fromMilliseconds(500), .retry = .{ .attempts = 1 }, .history = .forever });
const Skipper = Job(.{ .name = "skipper", .misfire = .{ .skip = .fromSeconds(1) }, .history = .forever });
const Ghostly = Job(.{ .name = "ghostly", .history = .forever });
const GhostlyOnce = Job(.{ .name = "ghostly-once", .retry = .{ .attempts = 1 }, .history = .forever });

/// Waits until a row of `ref` has `outcome`, and returns it.
fn rowOf(f: *Fixture, ref: scheduler.Ref, outcome: scheduler.RunOutcome) !scheduler.Run {
    const give_up = nowMs() + 5000;
    while (true) {
        for (try f.rows(ref)) |row| if (row.outcome == outcome) return row;
        if (nowMs() >= give_up) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// The record of `ref` moved to `at`, a moment before now.
fn moveBack(f: *Fixture, ref: scheduler.Ref, ms: i64) !void {
    const at: scheduler.Instant = .fromUnixMs(f.memory.store().now(io).unix_ms - ms);
    try testing.expectEqual(scheduler.Client.Changed.changed, try f.client.reschedule(io, .root, ref, .{ .at = at }, .{}));
}

/// Creates a record whose payload does not read as `{ n: u64 }`.
fn unreadable(f: *Fixture, ref: scheduler.Ref) !void {
    const options: Store.CallOptions = .{ .allocator = f.arena.allocator() };
    _ = try f.memory.store().create(io, .root, &.{ .job = ref.job, .key = ref.key, .life = @splat(5), .plan = "", .payload = "{\"n\":\"x\"}", .run_at = .{ .after = .zero } }, options);
}

test "a failing one-shot job retries and ends failed" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .fail = error.PaymentDeclined };
    var job: Failing = .{ .probe = &probe };
    try f.schedule(Failing, "x", .{ .after = .zero });
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Failing }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    const r = (try f.until(.of(Failing, "x"), .failed, 10)) orelse return error.TestUnexpectedResult;
    const last = r.last orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.failed, last.outcome);
    try testing.expectEqualDeep(@as(?[]const u8, "PaymentDeclined"), last.error_name);
    try testing.expectEqual(@as(u32, 3), last.attempt);
    try testing.expectEqual(@as(u32, 3), probe.runs.load(.acquire));
    try testing.expectEqual(@as(u64, 3), w.stats().failed);
    try testing.expectEqual(@as(u64, 1), w.stats().gave_up);
}

test "timeout cancels the run and counts as a failed attempt" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var job: Slow = .{ .probe = &probe };
    try f.schedule(Slow, "x", .{ .after = .zero });
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Slow }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    const row = try rowOf(&f, .of(Slow, "x"), .timed_out);
    try testing.expectEqualDeep(@as(?[]const u8, "Timeout"), row.error_name);
    try testing.expectEqual(@as(u32, 1), probe.cancelled.load(.acquire));
    try testing.expect(probe.stopped.load(.acquire) - probe.started.load(.acquire) < 2000);
    try testing.expectEqual(@as(u64, 1), w.stats().timed_out);
    try testing.expectEqual(@as(u64, 1), w.stats().failed);
}

test "an unconfirmed lease cancels the run before anyone can take it over" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var job: Kept = .{ .probe = &probe };
    try f.schedule(Kept, "x", .{ .after = .zero });
    f.faulty.failNext(io, .renew, error.Unavailable, 1000);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var options = quick;
    options.shutdown_grace = .fromMilliseconds(300);
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    try w.start(io);
    // Read before the record comes back: the next run starts at once.
    try reach(&probe.runs, 1, 5);
    const started = probe.started.load(.acquire);
    try reach(&probe.ended, 1, 6);
    // The local deadline: the claim, plus lease − renew_every, 2 s; not
    // the first renewal that failed, 1 s after the claim.
    const held = probe.stopped.load(.acquire) - started;
    try testing.expect(held >= 1300 and held < 3000);
    try testing.expectEqualDeep(@as(?[]const u8, "LeaseUnconfirmed"), (try rowOf(&f, .of(Kept, "x"), .interrupted)).error_name);
    // Back with the attempt not counted: the next claim is attempt 1 again.
    try reach(&probe.runs, 2, 5);
    try testing.expectEqual(@as(u32, 1), probe.attempt.load(.acquire));
    try testing.expect(w.stats().lost >= 1);
}

test "a lease taken over: the late owner is refused and its row replaces abandoned" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var job: Kept = .{ .probe = &probe };
    try f.schedule(Kept, "x", .{ .after = .zero });
    var options = quick;
    options.workers = 1;
    options.lease = .fromSeconds(6);
    options.renew_every = .fromSeconds(2);
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const ref: scheduler.Ref = .of(Kept, "x");
    const ran = (try f.get(ref)) orelse return error.TestUnexpectedResult;
    const owner = ran.owner orelse return error.TestUnexpectedResult;
    const claimed_at = ran.claimed_at orelse return error.TestUnexpectedResult;

    // The thief: the same life again, claimed until it holds fence 2, with
    // the worker's attempt written as abandoned on the way.
    const s = f.memory.store();
    const a: Store.CallOptions = .{ .allocator = f.arena.allocator() };
    _ = try s.remove(io, .root, &ref, a);
    _ = try s.create(io, .root, &.{ .job = "kept", .key = "x", .life = ran.life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } }, a);
    const claim: Store.ClaimRequest = .{ .owner = "thief", .any_key = &.{}, .keyed_only = &.{"kept"}, .max = 1, .lease = .fromSeconds(60), .tag = @splat(1) };
    const first = (try s.claim(io, .root, &claim, a)).claimed;
    if (first.len != 1) return error.TestUnexpectedResult;
    const row: scheduler.Run = .{ .job = "kept", .key = "x", .tenant = null, .life = ran.life, .fence = 1, .attempt = 1, .scheduled_at = ran.scheduled_at, .started_at = claimed_at, .finished_at = claimed_at, .outcome = .abandoned, .error_name = null, .instance = owner, .expires_at = null };
    const back: Store.Next = .{ .wait = .{ .state = .pending, .run_at = .{ .after = .zero }, .scheduled_at = null, .attempt = 0 } };
    const finish: Store.FinishRequest = .{ .ref = ref, .life = ran.life, .owner = "thief", .fence = 1, .revision = first[0].record.revision, .tag = @splat(2), .next = back, .last = null, .history = .{ .runs = &.{row}, .keep = .forever } };
    try testing.expectEqual(Store.FinishResult.done, try s.finish(io, .root, &finish, a));
    const second = (try s.claim(io, .root, &claim, a)).claimed;
    if (second.len != 1 or second[0].record.fence != 2) return error.TestUnexpectedResult;

    const late = try rowOf(&f, ref, .interrupted);
    try testing.expectEqualDeep(@as(?[]const u8, "LeaseLost"), late.error_name);
    try testing.expectEqual(@as(usize, 1), (try f.rows(ref)).len);
    const now = (try f.get(ref)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(@as(?[]const u8, "thief"), now.owner);
    try testing.expectEqual(@as(u64, 2), now.fence);
    try testing.expectEqual(@as(u64, 1), w.stats().lost);
}

test "cancel of a running job stops it at the next renewal" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var job: Kept = .{ .probe = &probe };
    try f.schedule(Kept, "x", .{ .after = .zero });
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    try testing.expect(try f.client.cancel(io, .root, .of(Kept, "x"), .{}));
    try testing.expectEqualDeep(@as(?[]const u8, "Cancelled"), (try rowOf(&f, .of(Kept, "x"), .interrupted)).error_name);
    try testing.expect(probe.stopped.load(.acquire) - probe.started.load(.acquire) < 2500);
    try testing.expectEqual(@as(u64, 1), w.stats().removed);
    try testing.expectEqual(null, try f.get(.of(Kept, "x")));
}

test "a re-created key is a new life the old run does not touch" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromSeconds(10) };
    var job: Kept = .{ .probe = &probe };
    try f.schedule(Kept, "x", .{ .after = .zero });
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var options = quick;
    options.workers = 2;
    options.shutdown_grace = .fromMilliseconds(300);
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 1, 5);
    const old = (try f.get(.of(Kept, "x"))) orelse return error.TestUnexpectedResult;
    try testing.expect(try f.client.cancel(io, .root, .of(Kept, "x"), .{}));
    try f.schedule(Kept, "x", .{ .after = .zero });
    try reach(&probe.runs, 2, 5);
    try reach(&probe.cancelled, 1, 5);
    const row = try rowOf(&f, .of(Kept, "x"), .interrupted);
    try testing.expectEqualSlices(u8, &old.life, &row.life);
    try testing.expectEqualDeep(@as(?[]const u8, "Cancelled"), row.error_name);
    const new = (try f.get(.of(Kept, "x"))) orelse return error.TestUnexpectedResult;
    try testing.expect(!std.mem.eql(u8, &old.life, &new.life));
    try testing.expectEqual(scheduler.State.running, new.state);
    try testing.expectEqual(@as(u64, 1), new.fence);
}

test "a late run past its skip threshold writes skipped and runs nothing" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Skipper = .{ .probe = &probe };
    try f.schedule(Skipper, "x", .{ .repeat = .everyHours(1) });
    try moveBack(&f, .of(Skipper, "x"), 10 * 60 * 1000);
    var w: scheduler.Worker(struct { job: *Skipper }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    _ = try rowOf(&f, .of(Skipper, "x"), .skipped);
    const r = (try f.until(.of(Skipper, "x"), .pending, 5)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.skipped, (r.last orelse return error.TestUnexpectedResult).outcome);
    try testing.expect(r.scheduled_at.unix_ms > f.memory.store().now(io).unix_ms);
    try testing.expectEqual(@as(u32, 0), probe.runs.load(.acquire));
    try testing.expectEqual(@as(u64, 1), w.stats().skipped);
}

test "coalesce runs once for the missed moments" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Ghostly = .{ .probe = &probe };
    try f.schedule(Ghostly, "x", .{ .repeat = .everyHours(1) });
    try moveBack(&f, .of(Ghostly, "x"), 3 * 60 * 60 * 1000);
    var w: scheduler.Worker(struct { job: *Ghostly }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.ended, 1, 5);
    try testing.expect(probe.missed.load(.acquire) >= 2);
    _ = try rowOf(&f, .of(Ghostly, "x"), .succeeded);
    try io.sleep(.fromMilliseconds(300), .awake);
    try testing.expectEqual(@as(u32, 1), probe.runs.load(.acquire));
    try testing.expectEqual(@as(u64, 1), w.stats().coalesced);
}

test "an abandoned attempt is written by the claim that takes it over" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var once_probe: Probe = .{};
    var ghostly: Ghostly = .{ .probe = &probe };
    var once: GhostlyOnce = .{ .probe = &once_probe };
    try f.schedule(Ghostly, "x", .{ .after = .zero });
    try f.schedule(GhostlyOnce, "x", .{ .after = .zero });
    const claim: Store.ClaimRequest = .{ .owner = "ghost", .any_key = &.{}, .keyed_only = &.{ "ghostly", "ghostly-once" }, .max = 2, .lease = .fromSeconds(1), .tag = @splat(1) };
    const ghost = (try f.memory.store().claim(io, .root, &claim, .{ .allocator = f.arena.allocator() })).claimed;
    if (ghost.len != 2) return error.TestUnexpectedResult;
    const ghost_at = ghost[0].record.claimed_at orelse return error.TestUnexpectedResult;
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { ghostly: *Ghostly, once: *GhostlyOnce }) = try .init(testing.allocator, io, f.store(), .{ .ghostly = &ghostly, .once = &once }, quick);
    defer w.deinit(io);
    try w.start(io);
    const row = try rowOf(&f, .of(Ghostly, "x"), .abandoned);
    try testing.expectEqualStrings("ghost", row.instance);
    try testing.expectEqual(ghost_at, row.started_at);
    try testing.expectEqual(@as(u64, 1), row.fence);
    try testing.expectEqual(@as(u64, 2), (try rowOf(&f, .of(Ghostly, "x"), .succeeded)).fence);
    // The abandoned attempt was the last one: nothing runs.
    const failed = (try f.until(.of(GhostlyOnce, "x"), .failed, 5)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.abandoned, (failed.last orelse return error.TestUnexpectedResult).outcome);
    _ = try rowOf(&f, .of(GhostlyOnce, "x"), .abandoned);
    try testing.expectEqual(@as(u32, 1), probe.runs.load(.acquire));
    try testing.expectEqual(@as(u32, 0), once_probe.runs.load(.acquire));
    try testing.expectEqual(@as(u64, 2), w.stats().taken_over);
}

test "a payload this worker cannot read goes back for a minute without a row or last" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Kept = .{ .probe = &probe };
    try unreadable(&f, .of(Kept, "x"));
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    const give_up = nowMs() + 5000;
    while (w.stats().unreadable < 1) : (try io.sleep(.fromMilliseconds(5), .awake)) if (nowMs() >= give_up) return error.Timeout;
    const back = (try f.get(.of(Kept, "x"))) orelse return error.TestUnexpectedResult;
    const in = (back.run_at orelse return error.TestUnexpectedResult).unix_ms - f.memory.store().now(io).unix_ms;
    try testing.expect(in > 50_000 and in <= 60_000);
    try testing.expectEqual(@as(u32, 0), back.attempt);
    try testing.expectEqual(@as(u64, 1), back.fence);
    try testing.expect(back.unreadable_since != null);
    try testing.expectEqual(null, back.last);
    try testing.expectEqual(@as(usize, 0), (try f.rows(.of(Kept, "x"))).len);
    try testing.expectEqual(@as(u32, 0), probe.runs.load(.acquire));
}

test "unreadable past unreadable_limit ends failed" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{};
    var job: Kept = .{ .probe = &probe };
    try unreadable(&f, .of(Kept, "x"));
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var options = quick;
    options.unreadable_limit = .fromMilliseconds(500);
    var w: scheduler.Worker(struct { job: *Kept }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    try w.start(io);
    const give_up = nowMs() + 5000;
    while (w.stats().unreadable < 1) : (try io.sleep(.fromMilliseconds(5), .awake)) if (nowMs() >= give_up) return error.Timeout;
    try io.sleep(.fromMilliseconds(600), .awake);
    try testing.expectEqual(scheduler.Client.Changed.changed, try f.client.reschedule(io, .root, .of(Kept, "x"), .{ .after = .zero }, .{}));
    const r = (try f.until(.of(Kept, "x"), .failed, 5)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(@as(?[]const u8, "UnreadablePayload"), (r.last orelse return error.TestUnexpectedResult).error_name);
    try testing.expectEqual(@as(u64, 1), w.stats().gave_up);
}

test "a recurring job whose run outlasts its period runs one at a time" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromMilliseconds(2500) };
    var job: Ghostly = .{ .probe = &probe };
    try f.schedule(Ghostly, "x", .{ .repeat = .everySeconds(1) });
    var w: scheduler.Worker(struct { job: *Ghostly }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, quick);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 2, 10);
    // The second run started at once after the first ended, for the
    // moments the first one outlasted.
    try testing.expect(probe.started.load(.acquire) - probe.stopped.load(.acquire) < 1000);
    try testing.expect(probe.missed.load(.acquire) >= 1);
    try reach(&probe.ended, 2, 10);
    try testing.expectEqual(@as(u32, 1), probe.most.load(.acquire));
}

test "stats follow the slots and the runs" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var probe: Probe = .{ .hold = .fromMilliseconds(1000) };
    var job: Ghostly = .{ .probe = &probe };
    for ([_][]const u8{ "a", "b", "c" }) |key| try f.schedule(Ghostly, key, .{ .after = .zero });
    var options = quick;
    options.workers = 4;
    var w: scheduler.Worker(struct { job: *Ghostly }) = try .init(testing.allocator, io, f.store(), .{ .job = &job }, options);
    defer w.deinit(io);
    try w.start(io);
    try reach(&probe.runs, 3, 5);
    try testing.expectEqual(@as(u16, 4), w.stats().workers);
    try testing.expectEqual(@as(u16, 3), w.stats().running);
    try reach(&probe.ended, 3, 5);
    const give_up = nowMs() + 5000;
    while (w.stats().succeeded < 3) : (try io.sleep(.fromMilliseconds(5), .awake)) if (nowMs() >= give_up) return error.Timeout;
    const s = w.stats();
    try testing.expectEqual(@as(u16, 0), s.running);
    try testing.expectEqual(@as(u64, 3), s.claimed);
    try testing.expectEqual(@as(u64, 0), s.taken_over);
    try testing.expectEqual(@as(u64, 0), s.failed);
}
