//! Tests of the transition of a finished claim: a test for each row of the
//! table of §9.5 of the design, for a one-shot and a repeating record where
//! the row has both. A record is claimed at 2026-10-24T03:30:02Z, two
//! seconds after its scheduled time; its policy is the default, with a
//! history kept 90 days.

const std = @import("std");
const testing = std.testing;
const Duration = std.Io.Duration;
const scheduler = @import("../root.zig");
const transition = @import("../worker/transition.zig");
const Policy = @import("../worker/policy.zig").Policy;
const Decision = transition.Decision;
const Ending = transition.Ending;
const Store = scheduler.Store;
const Next = Store.Next;
const Record = scheduler.Record;
const Run = scheduler.Run;
const LastRun = scheduler.LastRun;
const RunOutcome = scheduler.RunOutcome;
const Instant = scheduler.Instant;

const day = 24 * 60 * 60;
const scheduled: Instant = .fromUtc(2026, 10, 24, 3, 30, 0, .h24);
const claimed: Instant = .fromUtc(2026, 10, 24, 3, 30, 2, .h24);
/// The next moment of `daily` after the claim.
const tomorrow: Instant = .fromUtc(2026, 10, 25, 3, 30, 0, .h24);
/// The owner of the claim, and the owner of the claim before it, which the
/// claim took over.
const owner = "shop/00112233445566778899aabbccddeeff";
const previous = "shop/ffeeddccbbaa99887766554433221100";
/// When the claim that a takeover took over was made.
const taken_at: Instant = .fromUtc(2026, 10, 24, 3, 29, 0, .h24);

const one_shot = "";
const daily = "daily 03:30:00";

/// The default policy, with a history kept 90 days.
const base: Policy = .{
    .name = "send-invoice",
    .timeout = null,
    .retry = .{},
    .misfire = .coalesce,
    .history = .{ .keep_for = .fromSeconds(90 * day) },
    .when_done = .{},
    .repeat = null,
};

/// A record as a claim returns it: running, at its first attempt.
fn claim(plan: []const u8) Record {
    return .{
        .job = "send-invoice",
        .key = "order-42",
        .tenant = "acme",
        .state = .running,
        .plan = plan,
        .payload = "{\"order_id\":42}",
        .scheduled_at = scheduled,
        .run_at = null,
        .attempt = 1,
        .fence = 1,
        .revision = 3,
        .pause_requested = false,
        .owner = owner,
        .claimed_at = claimed,
        .lease_until = claimed.add(.fromSeconds(60)),
        .last = null,
        .created_at = scheduled,
        .updated_at = scheduled,
        .finished_at = null,
        .expires_at = null,
        .trace = null,
        .life = @splat(7),
        .unreadable_since = null,
    };
}

/// The same record at its `attempt`-th claim.
fn claimAt(plan: []const u8, attempt: u32) Record {
    var r = claim(plan);
    r.attempt = attempt;
    r.fence = attempt;
    return r;
}

/// The claim that the claim of `r` took over, with nothing moved between
/// them: the attempt before, the same moment.
fn tookOver(r: *const Record) Store.TookOver {
    return .{ .owner = previous, .claimed_at = taken_at, .attempt = r.attempt -| 1, .scheduled_at = r.scheduled_at };
}

/// What a decision takes besides the record and the ending.
const With = struct {
    policy: *const Policy = &base,
    took_over: ?Store.TookOver = null,
    current: ?*const Record = null,
    unreadable_limit: Duration = .fromSeconds(60 * 60),
};

fn decide(r: *const Record, ending: Ending, with: With) Decision {
    var prng: std.Random.DefaultPrng = .init(42);
    return transition.decide(.{
        .policy = with.policy,
        .claimed = r,
        .took_over = with.took_over,
        .ending = ending,
        .current = with.current,
        .instance = owner,
        .unreadable_limit = with.unreadable_limit,
        .random = prng.random(),
    });
}

/// A repeating record waits for its next run: a new scheduled_at, attempt 0.
fn nextRun(run_at: Store.Moment) Next {
    return .{ .wait = .{ .state = .pending, .run_at = run_at, .scheduled_at = null, .attempt = 0 } };
}

/// The record back at once for the same run, this attempt not counted.
fn back(r: *const Record) Next {
    return .{ .wait = .{ .state = .pending, .run_at = .{ .after = .zero }, .scheduled_at = r.scheduled_at, .attempt = r.attempt - 1 } };
}

fn finished(state: scheduler.State, keep: scheduler.Retention) Next {
    return .{ .done = .{ .state = state, .keep = keep } };
}

const kept_failed: scheduler.Retention = .{ .keep_for = .fromSeconds(30 * day) };

/// The row of the claim of `r`. The store puts its own moment over
/// `finished_at`; the decision leaves the moment of the claim there.
fn row(r: *const Record, outcome: RunOutcome, error_name: ?[]const u8) Run {
    const at = r.claimed_at orelse claimed;
    return .{
        .job = r.job,
        .key = r.key,
        .tenant = r.tenant,
        .life = r.life,
        .fence = r.fence,
        .attempt = r.attempt,
        .scheduled_at = r.scheduled_at,
        .started_at = at,
        .finished_at = at,
        .outcome = outcome,
        .error_name = error_name,
        .instance = owner,
        .expires_at = null,
    };
}

/// The row of the abandoned attempt that the claim of `r` took over.
fn abandoned(r: *const Record) Run {
    var run = row(r, .abandoned, null);
    run.fence = r.fence - 1;
    run.attempt = r.attempt - 1;
    run.started_at = taken_at;
    run.instance = previous;
    return run;
}

fn last(r: *const Record, outcome: RunOutcome, error_name: ?[]const u8) ?LastRun {
    const at = r.claimed_at orelse claimed;
    return .{ .outcome = outcome, .error_name = error_name, .attempt = r.attempt, .started_at = at, .finished_at = at };
}

fn expectRows(expected: []const Run, d: *const Decision) !void {
    try testing.expectEqualDeep(expected, d.runs());
}

/// The record waits the pause after its attempt, 80–100 % of `full`, for
/// the same run: its scheduled_at and attempt stay.
fn expectRetry(d: *const Decision, r: *const Record, full: Duration) !void {
    const wait = switch (d.next) {
        .wait => |wait| wait,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(scheduler.State.pending, wait.state);
    try testing.expectEqual(@as(?Instant, r.scheduled_at), wait.scheduled_at);
    try testing.expectEqual(r.attempt, wait.attempt);
    try testing.expectEqual(@as(?Instant, null), wait.unreadable_since);
    const pause = switch (wait.run_at) {
        .after => |after| after.nanoseconds,
        .at => return error.TestUnexpectedResult,
    };
    try testing.expect(pause <= full.nanoseconds and pause >= @divTrunc(full.nanoseconds, 5) * 4);
    try testing.expect(d.event == .retry);
}

test "success: deleted or kept by when_done; recurring waits for its next moment" {
    // One-shot: deleted at once by default, or kept for a time or always.
    const r = claim(one_shot);
    var d = decide(&r, .succeeded, .{});
    try testing.expectEqual(@as(Next, .delete), d.next);
    try testing.expectEqualDeep(last(&r, .succeeded, null), d.last);
    try expectRows(&.{row(&r, .succeeded, null)}, &d);
    try testing.expect(d.event == .none);
    var kept = base;
    kept.when_done.succeeded = .{ .keep_for = .fromSeconds(7 * day) };
    d = decide(&r, .succeeded, .{ .policy = &kept });
    try testing.expectEqual(finished(.succeeded, .{ .keep_for = .fromSeconds(7 * day) }), d.next);
    kept.when_done.succeeded = .forever;
    d = decide(&r, .succeeded, .{ .policy = &kept });
    try testing.expectEqual(finished(.succeeded, .forever), d.next);

    // Repeating: the next moment of its plan after the claim, attempt 0.
    const repeating = claim(daily);
    d = decide(&repeating, .succeeded, .{});
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);
    try testing.expectEqualDeep(last(&repeating, .succeeded, null), d.last);
    try expectRows(&.{row(&repeating, .succeeded, null)}, &d);
    try testing.expect(d.event == .none);
    // fixedDelay: its delay after the transition, which the store counts.
    const delayed = claim("delay 30s");
    d = decide(&delayed, .succeeded, .{});
    try testing.expectEqual(nextRun(.{ .after = .fromSeconds(30) }), d.next);
    // A run that stood for missed moments: one run for them all, and the
    // next moment after the claim.
    var late = claim("every 60s");
    late.claimed_at = scheduled.add(.fromSeconds(150));
    d = decide(&late, .succeeded, .{});
    try testing.expectEqual(nextRun(.{ .at = scheduled.add(.fromSeconds(180)) }), d.next);
    try testing.expect(d.event == .coalesced);
}

test "a failure with attempts left waits the retry pause with the same scheduled_at" {
    // The first of five attempts of a one-shot record: 1 s, cut by up to
    // 20 %.
    const first = claim(one_shot);
    var d = decide(&first, .{ .failed = error.PaymentDeclined }, .{});
    try expectRetry(&d, &first, .fromSeconds(1));
    try testing.expectEqualDeep(last(&first, .failed, "PaymentDeclined"), d.last);
    try expectRows(&.{row(&first, .failed, "PaymentDeclined")}, &d);
    // A timeout is a failed attempt too; after the fourth, 125 s is cut to
    // 120 s.
    const fourth = claimAt(one_shot, 4);
    d = decide(&fourth, .timed_out, .{});
    try expectRetry(&d, &fourth, .fromSeconds(120));
    try testing.expectEqualDeep(last(&fourth, .timed_out, "Timeout"), d.last);
    try expectRows(&.{row(&fourth, .timed_out, "Timeout")}, &d);
    // A repeating record with attempts of its own retries the same way.
    var three = base;
    three.retry.attempts = 3;
    const repeating = claimAt(daily, 2);
    d = decide(&repeating, .timed_out, .{ .policy = &three });
    try expectRetry(&d, &repeating, .fromSeconds(5));
    d = decide(&repeating, .{ .failed = error.PaymentDeclined }, .{ .policy = &three });
    try expectRetry(&d, &repeating, .fromSeconds(5));
}

test "attempts spent or give_up_on: one-shot done(failed) or deleted at .none; recurring goes on with last failed" {
    // The fifth of five attempts: failed, kept 30 days by default.
    const fifth = claimAt(one_shot, 5);
    var d = decide(&fifth, .{ .failed = error.PaymentDeclined }, .{});
    try testing.expectEqual(finished(.failed, kept_failed), d.next);
    try testing.expectEqualDeep(last(&fifth, .failed, "PaymentDeclined"), d.last);
    try expectRows(&.{row(&fifth, .failed, "PaymentDeclined")}, &d);
    try testing.expect(d.event == .gave_up);
    d = decide(&fifth, .timed_out, .{});
    try testing.expectEqual(finished(.failed, kept_failed), d.next);
    try testing.expect(d.event == .gave_up);

    // An error of give_up_on ends the first attempt; `.none` deletes the
    // failed record. A timeout gives up when error.Timeout is there.
    var gone = base;
    gone.retry.give_up_on = &.{ error.OrderGone, error.Timeout };
    gone.when_done.failed = .none;
    const first = claim(one_shot);
    d = decide(&first, .{ .failed = error.OrderGone }, .{ .policy = &gone });
    try testing.expectEqual(@as(Next, .delete), d.next);
    try testing.expectEqualDeep(last(&first, .failed, "OrderGone"), d.last);
    try testing.expect(d.event == .gave_up);
    d = decide(&first, .timed_out, .{ .policy = &gone });
    try testing.expectEqual(@as(Next, .delete), d.next);
    gone.when_done.failed = .forever;
    d = decide(&first, .{ .failed = error.OrderGone }, .{ .policy = &gone });
    try testing.expectEqual(finished(.failed, .forever), d.next);

    // A repeating record (one attempt by default) goes on to its next
    // moment, with its failure in `last`.
    const repeating = claim(daily);
    d = decide(&repeating, .{ .failed = error.PaymentDeclined }, .{});
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);
    try testing.expectEqualDeep(last(&repeating, .failed, "PaymentDeclined"), d.last);
    try expectRows(&.{row(&repeating, .failed, "PaymentDeclined")}, &d);
    try testing.expect(d.event == .none);
    d = decide(&repeating, .{ .failed = error.OrderGone }, .{ .policy = &gone });
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);
}

test "interrupted by the Worker: back at once, attempt − 1, a row with Shutdown or LeaseUnconfirmed" {
    for ([_][]const u8{ one_shot, daily }) |plan| {
        const r = claimAt(plan, 2);
        var d = decide(&r, .{ .interrupted = .shutdown }, .{});
        try testing.expectEqual(back(&r), d.next);
        try testing.expectEqualDeep(last(&r, .interrupted, "Shutdown"), d.last);
        try expectRows(&.{row(&r, .interrupted, "Shutdown")}, &d);
        try testing.expect(d.event == .none);
        d = decide(&r, .{ .interrupted = .lease_unconfirmed }, .{});
        try testing.expectEqual(back(&r), d.next);
        try testing.expectEqualDeep(last(&r, .interrupted, "LeaseUnconfirmed"), d.last);
        try expectRows(&.{row(&r, .interrupted, "LeaseUnconfirmed")}, &d);
    }
}

test "claimed and not started at a stop: back at once, without a row, last untouched" {
    for ([_][]const u8{ one_shot, daily }) |plan| {
        const r = claimAt(plan, 3);
        const d = decide(&r, .not_started, .{});
        try testing.expectEqual(back(&r), d.next);
        try testing.expectEqual(@as(?LastRun, null), d.last);
        try expectRows(&.{}, &d);
        try testing.expect(d.event == .none);
    }
}

test "lost and removed: rows interrupted with LeaseLost and Cancelled" {
    // The store refuses the transition of a claim that is not its owner's
    // any more; the rows go in all the same. The transition sent is a valid
    // one: a store checks it before it writes the rows.
    for ([_][]const u8{ one_shot, daily }) |plan| {
        const r = claimAt(plan, 2);
        var d = decide(&r, .lost, .{});
        try expectRows(&.{row(&r, .interrupted, "LeaseLost")}, &d);
        try testing.expectEqualDeep(last(&r, .interrupted, "LeaseLost"), d.last);
        try testing.expectEqual(back(&r), d.next);
        d = decide(&r, .removed, .{});
        try expectRows(&.{row(&r, .interrupted, "Cancelled")}, &d);
        try testing.expectEqualDeep(last(&r, .interrupted, "Cancelled"), d.last);
        try testing.expectEqual(back(&r), d.next);
    }
}

test "a takeover adds the abandoned row of the attempt before, started at its claimed_at" {
    // The run goes as usual; its finish carries the row of the attempt
    // whose owner was lost, first.
    const r = claimAt(one_shot, 2);
    var d = decide(&r, .succeeded, .{ .took_over = tookOver(&r) });
    try expectRows(&.{ abandoned(&r), row(&r, .succeeded, null) }, &d);
    try testing.expectEqual(@as(Next, .delete), d.next);
    try testing.expectEqualDeep(last(&r, .succeeded, null), d.last);
    const repeating = claimAt(daily, 2);
    d = decide(&repeating, .{ .failed = error.PaymentDeclined }, .{ .took_over = tookOver(&repeating) });
    try expectRows(&.{ abandoned(&repeating), row(&repeating, .failed, "PaymentDeclined") }, &d);
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);

    // The abandoned attempt may have had effects, so its row goes in even
    // when this claim does not run: a return without a row of its own.
    d = decide(&r, .not_started, .{ .took_over = tookOver(&r) });
    try expectRows(&.{abandoned(&r)}, &d);
    try testing.expectEqual(back(&r), d.next);
    try testing.expectEqual(@as(?LastRun, null), d.last);
    d = decide(&r, .{ .unreadable = .payload }, .{ .took_over = tookOver(&r) });
    try expectRows(&.{abandoned(&r)}, &d);
    try testing.expectEqual(@as(?LastRun, null), d.last);
}

test "the abandoned attempt was the last: one-shot done(failed), recurring next moment, last abandoned" {
    // Five attempts by default: the sixth claim took over the fifth.
    const r = claimAt(one_shot, 6);
    const shown: ?LastRun = .{ .outcome = .abandoned, .error_name = null, .attempt = 5, .started_at = taken_at, .finished_at = claimed };
    var d = decide(&r, .abandoned_last, .{ .took_over = tookOver(&r) });
    try testing.expectEqual(finished(.failed, kept_failed), d.next);
    try testing.expectEqualDeep(shown, d.last);
    try expectRows(&.{abandoned(&r)}, &d);
    try testing.expect(d.event == .gave_up);
    var gone = base;
    gone.when_done.failed = .none;
    d = decide(&r, .abandoned_last, .{ .took_over = tookOver(&r), .policy = &gone });
    try testing.expectEqual(@as(Next, .delete), d.next);

    // One attempt of a repeating record: its next moment, attempt 0.
    const repeating = claimAt(daily, 2);
    d = decide(&repeating, .abandoned_last, .{ .took_over = tookOver(&repeating) });
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);
    try testing.expectEqualDeep(@as(?LastRun, .{ .outcome = .abandoned, .error_name = null, .attempt = 1, .started_at = taken_at, .finished_at = claimed }), d.last);
    try expectRows(&.{abandoned(&repeating)}, &d);
    try testing.expect(d.event == .none);
}

test "the abandoned last attempt of a frequent plan: its next moment, and no run that stood for the missed ones" {
    // A takeover comes once the lease of the abandoned attempt has ended, a
    // minute after its claim by default: a plan of every 15 or 60 s has
    // moments in between, and no run stood for them.
    const prior: Store.TookOver = .{ .owner = previous, .claimed_at = scheduled, .attempt = 1, .scheduled_at = scheduled };
    const taken_over_at = scheduled.add(.fromSeconds(61));
    for ([_]struct { plan: []const u8, next: Instant }{
        .{ .plan = "every 15s", .next = scheduled.add(.fromSeconds(75)) },
        .{ .plan = "every 60s", .next = scheduled.add(.fromSeconds(120)) },
    }) |case| {
        var r = claimAt(case.plan, 2);
        r.claimed_at = taken_over_at;
        const d = decide(&r, .abandoned_last, .{ .took_over = prior });
        try testing.expectEqual(nextRun(.{ .at = case.next }), d.next);
        try testing.expectEqualDeep(@as(?LastRun, .{ .outcome = .abandoned, .error_name = null, .attempt = 1, .started_at = scheduled, .finished_at = taken_over_at }), d.last);
        try testing.expect(d.event == .none);
    }
}

test "skipped: a skipped row, last skipped, the next moment after the claim" {
    var skipping = base;
    skipping.misfire = .{ .skip = .fromSeconds(15 * 60) };
    // The run of yesterday, claimed today: no run, and the next is
    // tomorrow's, not today's, which passed with the claim.
    var r = claim(daily);
    r.scheduled_at = .fromUtc(2026, 10, 23, 3, 30, 0, .h24);
    var d = decide(&r, .skipped, .{ .policy = &skipping });
    try testing.expectEqual(nextRun(.{ .at = tomorrow }), d.next);
    try testing.expectEqualDeep(last(&r, .skipped, null), d.last);
    try expectRows(&.{row(&r, .skipped, null)}, &d);
    try testing.expect(d.event == .skipped);
    // A takeover of an abandoned attempt that came too late: both rows.
    d = decide(&r, .skipped, .{ .policy = &skipping, .took_over = tookOver(&r) });
    try expectRows(&.{ abandoned(&r), row(&r, .skipped, null) }, &d);
}

test "unreadable: back in 60 s, attempt − 1, unreadable_since kept or set to claimed_at, no row, last untouched" {
    for ([_][]const u8{ one_shot, daily }) |plan| {
        // The first instance that cannot read it: since this claim.
        var r = claimAt(plan, 2);
        var d = decide(&r, .{ .unreadable = .payload }, .{});
        try testing.expectEqual(Next{ .wait = .{
            .state = .pending,
            .run_at = .{ .after = .fromSeconds(60) },
            .scheduled_at = scheduled,
            .attempt = 1,
            .unreadable_since = claimed,
        } }, d.next);
        try testing.expectEqual(@as(?LastRun, null), d.last);
        try expectRows(&.{}, &d);
        try testing.expect(d.event == .unreadable);
        // Another one could not read it either, half an hour ago: that
        // moment stays.
        const since: Instant = .fromUtc(2026, 10, 24, 3, 0, 2, .h24);
        r.unreadable_since = since;
        d = decide(&r, .{ .unreadable = .schedule }, .{});
        try testing.expectEqual(Next{ .wait = .{
            .state = .pending,
            .run_at = .{ .after = .fromSeconds(60) },
            .scheduled_at = scheduled,
            .attempt = 1,
            .unreadable_since = since,
        } }, d.next);
        try testing.expectEqual(@as(?LastRun, null), d.last);
        try expectRows(&.{}, &d);
    }
}

test "unreadable for unreadable_limit: done(failed) with UnreadablePayload or UnreadableSchedule, no row" {
    const hour: Duration = .fromSeconds(60 * 60);
    for ([_][]const u8{ one_shot, daily }) |plan| {
        var r = claim(plan);
        // A millisecond short of the hour: back once more.
        r.unreadable_since = claimed.add(.fromMilliseconds(-60 * 60 * 1000 + 1));
        var d = decide(&r, .{ .unreadable = .payload }, .{ .unreadable_limit = hour });
        try testing.expect(d.next == .wait);
        try testing.expect(d.event == .unreadable);
        // The hour: failed by when_done.failed, `last` says why.
        r.unreadable_since = claimed.add(.fromSeconds(-60 * 60));
        d = decide(&r, .{ .unreadable = .payload }, .{ .unreadable_limit = hour });
        try testing.expectEqual(finished(.failed, kept_failed), d.next);
        try testing.expectEqualDeep(last(&r, .failed, "UnreadablePayload"), d.last);
        try expectRows(&.{}, &d);
        try testing.expect(d.event == .unreadable_gave_up);
        d = decide(&r, .{ .unreadable = .schedule }, .{ .unreadable_limit = hour });
        try testing.expectEqual(finished(.failed, kept_failed), d.next);
        try testing.expectEqualDeep(last(&r, .failed, "UnreadableSchedule"), d.last);
        try testing.expect(d.event == .unreadable_gave_up);
    }
    // A limit of zero gives up at the first claim that cannot read it.
    const r = claim(one_shot);
    const d = decide(&r, .{ .unreadable = .payload }, .{ .unreadable_limit = .zero });
    try testing.expectEqual(finished(.failed, kept_failed), d.next);
}

test "changed during the run: the new moment or the new plan, attempt 0, the outcome only in last" {
    // A one-shot record moved by `reschedule` while it ran: it waits for
    // the new moment, whatever its run did.
    const r = claim(one_shot);
    var moved = r;
    moved.attempt = 0;
    moved.scheduled_at = .fromUtc(2026, 10, 30, 0, 0, 0, .h24);
    moved.revision = 4;
    const at_new: Next = nextRun(.{ .at = moved.scheduled_at });
    var d = decide(&r, .succeeded, .{ .current = &moved });
    try testing.expectEqual(at_new, d.next);
    try testing.expectEqualDeep(last(&r, .succeeded, null), d.last);
    try expectRows(&.{row(&r, .succeeded, null)}, &d);
    try testing.expect(d.event == .none);
    // No retry and no giving up: the change wins.
    d = decide(&r, .{ .failed = error.PaymentDeclined }, .{ .current = &moved });
    try testing.expectEqual(at_new, d.next);
    try testing.expectEqualDeep(last(&r, .failed, "PaymentDeclined"), d.last);
    try testing.expect(d.event == .none);
    const fifth = claimAt(one_shot, 5);
    var fifth_moved = fifth;
    fifth_moved.attempt = 0;
    fifth_moved.scheduled_at = moved.scheduled_at;
    d = decide(&fifth, .{ .failed = error.PaymentDeclined }, .{ .current = &fifth_moved });
    try testing.expectEqual(at_new, d.next);
    // A run stopped by the worker goes to the new moment too, attempt 0.
    d = decide(&fifth, .{ .interrupted = .shutdown }, .{ .current = &fifth_moved });
    try testing.expectEqual(at_new, d.next);
    d = decide(&fifth, .not_started, .{ .current = &fifth_moved });
    try testing.expectEqual(at_new, d.next);

    // A repeating record with a new plan (written by the start of another
    // version while it ran): the next moment of the new plan after the
    // claim, and no retry of the old one.
    const repeating = claim(daily);
    var replanned = repeating;
    replanned.plan = "every 3600s";
    replanned.revision = 4;
    const next_hour: Next = nextRun(.{ .at = .fromUtc(2026, 10, 24, 4, 0, 0, .h24) });
    d = decide(&repeating, .succeeded, .{ .current = &replanned });
    try testing.expectEqual(next_hour, d.next);
    var three = base;
    three.retry.attempts = 3;
    d = decide(&repeating, .{ .failed = error.PaymentDeclined }, .{ .policy = &three, .current = &replanned });
    try testing.expectEqual(next_hour, d.next);
    try testing.expectEqualDeep(last(&repeating, .failed, "PaymentDeclined"), d.last);
    // Moved by `reschedule` (.at, or .repeat with its first moment): that
    // moment.
    var rescheduled = replanned;
    rescheduled.attempt = 0;
    rescheduled.scheduled_at = .fromUtc(2026, 10, 24, 12, 0, 0, .h24);
    d = decide(&repeating, .succeeded, .{ .current = &rescheduled });
    try testing.expectEqual(nextRun(.{ .at = rescheduled.scheduled_at }), d.next);
}

test "pause_requested turns wait(pending) into wait(paused)" {
    // Asked for during the run: the record of a `changed` finish.
    const r = claim(daily);
    var asked = r;
    asked.pause_requested = true;
    asked.revision = 4;
    var d = decide(&r, .succeeded, .{ .current = &asked });
    try testing.expectEqual(Next{ .wait = .{ .state = .paused, .run_at = .{ .at = tomorrow }, .scheduled_at = null, .attempt = 0 } }, d.next);

    // A retry, a return and an unreadable record pause the same way.
    const one = claimAt(one_shot, 2);
    var one_asked = one;
    one_asked.pause_requested = true;
    one_asked.revision = 4;
    d = decide(&one, .{ .failed = error.PaymentDeclined }, .{ .current = &one_asked });
    try testing.expect(d.next == .wait and d.next.wait.state == .paused);
    d = decide(&one, .{ .interrupted = .shutdown }, .{ .current = &one_asked });
    try testing.expectEqual(Next{ .wait = .{ .state = .paused, .run_at = .{ .after = .zero }, .scheduled_at = scheduled, .attempt = 1 } }, d.next);
    d = decide(&one, .{ .unreadable = .payload }, .{ .current = &one_asked });
    try testing.expect(d.next == .wait and d.next.wait.state == .paused);
    // A finished record has nothing to pause.
    d = decide(&one, .succeeded, .{ .current = &one_asked });
    try testing.expectEqual(@as(Next, .delete), d.next);
}

test "asked for during the abandoned attempt a claim took over, a pause holds without a run" {
    // Not run: paused for the same run, the attempt of this claim not
    // counted, `last` and the row of the abandoned attempt.
    for ([_][]const u8{ one_shot, daily }) |plan| {
        var r = claimAt(plan, 2);
        r.pause_requested = true;
        var d = decide(&r, .abandoned_paused, .{ .took_over = tookOver(&r) });
        try testing.expectEqual(Next{ .wait = .{ .state = .paused, .run_at = .{ .after = .zero }, .scheduled_at = scheduled, .attempt = 1 } }, d.next);
        try testing.expectEqualDeep(@as(?LastRun, .{ .outcome = .abandoned, .error_name = null, .attempt = 1, .started_at = taken_at, .finished_at = claimed }), d.last);
        try expectRows(&.{abandoned(&r)}, &d);
        try testing.expect(d.event == .none);
        // Taken back meanwhile: pending, due at once.
        var back_again = r;
        back_again.pause_requested = false;
        back_again.revision = 4;
        d = decide(&r, .abandoned_paused, .{ .took_over = tookOver(&r), .current = &back_again });
        try testing.expectEqual(back(&r), d.next);
        // Moved meanwhile: the new moment, still paused.
        var moved = r;
        moved.attempt = 0;
        moved.scheduled_at = .fromUtc(2026, 10, 30, 0, 0, 0, .h24);
        moved.revision = 4;
        d = decide(&r, .abandoned_paused, .{ .took_over = tookOver(&r), .current = &moved });
        try testing.expectEqual(Next{ .wait = .{ .state = .paused, .run_at = .{ .at = moved.scheduled_at }, .scheduled_at = null, .attempt = 0 } }, d.next);
    }
}

test "moved during the abandoned attempt a claim took over: no run, the new moment, the row as its claim gave it" {
    // The client moved the fifth attempt to the 30th; its owner was lost,
    // and the takeover made the record attempt 1, fence 6.
    for ([_][]const u8{ one_shot, daily }) |plan| {
        const fifth = claimAt(plan, 5);
        const prior: Store.TookOver = .{ .owner = previous, .claimed_at = taken_at, .attempt = 5, .scheduled_at = scheduled };
        var r = fifth;
        r.attempt = 1;
        r.fence = 6;
        r.scheduled_at = .fromUtc(2026, 10, 30, 0, 0, 0, .h24);
        r.revision = 4;
        var d = decide(&r, .abandoned_moved, .{ .took_over = prior });
        try testing.expectEqual(nextRun(.{ .at = r.scheduled_at }), d.next);
        try testing.expectEqualDeep(@as(?LastRun, .{ .outcome = .abandoned, .error_name = null, .attempt = 5, .started_at = taken_at, .finished_at = claimed }), d.last);
        // The row of the attempt as its claim gave it: attempt 5 of the run
        // of `scheduled`, whose run key it names.
        var row_of_fifth = abandoned(&r);
        row_of_fifth.attempt = 5;
        row_of_fifth.scheduled_at = scheduled;
        try expectRows(&.{row_of_fifth}, &d);
        try testing.expect(d.event == .none);
        // Asked for a pause too: paused at the new moment.
        var asked = r;
        asked.pause_requested = true;
        d = decide(&asked, .abandoned_moved, .{ .took_over = prior });
        try testing.expectEqual(Next{ .wait = .{ .state = .paused, .run_at = .{ .at = r.scheduled_at }, .scheduled_at = null, .attempt = 0 } }, d.next);
    }
}

test "no next moment within 9 years: failed with NoNextRun" {
    var r = claim("every 60s");
    r.scheduled_at = .fromUtc(9999, 12, 31, 23, 59, 0, .h24);
    r.claimed_at = .fromUtc(9999, 12, 31, 23, 59, 30, .h24);
    const d = decide(&r, .succeeded, .{});
    try testing.expectEqual(finished(.failed, kept_failed), d.next);
    try testing.expectEqualDeep(last(&r, .failed, "NoNextRun"), d.last);
    // The row still says what the run did.
    try expectRows(&.{row(&r, .succeeded, null)}, &d);
    try testing.expect(d.event == .no_next_run);
}

test "history .none writes no rows; keep_for and forever pass their keep" {
    const r = claimAt(daily, 2);
    var none = base;
    none.history = .none;
    var d = decide(&r, .succeeded, .{ .policy = &none, .took_over = tookOver(&r) });
    try expectRows(&.{}, &d);
    try testing.expect(d.keep == .none);
    // `last` does not depend on the history.
    try testing.expectEqualDeep(last(&r, .succeeded, null), d.last);
    d = decide(&r, .succeeded, .{ .took_over = tookOver(&r) });
    try testing.expectEqual(base.history, d.keep);
    try testing.expectEqual(@as(usize, 2), d.runs().len);
    var always = base;
    always.history = .forever;
    d = decide(&r, .succeeded, .{ .policy = &always, .took_over = tookOver(&r) });
    try testing.expect(d.keep == .forever);
    try testing.expectEqual(@as(usize, 2), d.runs().len);
}

test "every transition but an unreadable return clears unreadable_since" {
    // Another instance could not read the record; this one read and ran it.
    const since: Instant = .fromUtc(2026, 10, 24, 3, 0, 0, .h24);
    var repeating = claimAt(daily, 2);
    repeating.unreadable_since = since;
    var one = claimAt(one_shot, 2);
    one.unreadable_since = since;
    var skipping = base;
    skipping.misfire = .{ .skip = .fromSeconds(60) };
    const cases = [_]struct { r: *const Record, ending: Ending, policy: *const Policy = &base }{
        .{ .r = &repeating, .ending = .succeeded },
        .{ .r = &repeating, .ending = .skipped, .policy = &skipping },
        .{ .r = &repeating, .ending = .abandoned_last },
        .{ .r = &repeating, .ending = .abandoned_moved },
        .{ .r = &one, .ending = .abandoned_paused },
        .{ .r = &one, .ending = .{ .failed = error.PaymentDeclined } },
        .{ .r = &one, .ending = .{ .interrupted = .lease_unconfirmed } },
        .{ .r = &one, .ending = .not_started },
        .{ .r = &one, .ending = .lost },
    };
    for (cases) |case| {
        const d = decide(case.r, case.ending, .{ .policy = case.policy });
        const wait = switch (d.next) {
            .wait => |wait| wait,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(?Instant, null), wait.unreadable_since);
    }
    // Finished records lose it in the store; the unreadable return keeps it.
    const d = decide(&one, .{ .unreadable = .payload }, .{});
    const wait = switch (d.next) {
        .wait => |wait| wait,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(?Instant, since), wait.unreadable_since);
}

test "a plan that does not read here goes back in a minute for an instance that reads it" {
    // A newer version wrote a plan this one does not know while it ran.
    const r = claim(daily);
    var replanned = r;
    replanned.plan = "hourly 30 tz=Europe/Berlin";
    replanned.revision = 4;
    const d = decide(&r, .succeeded, .{ .current = &replanned });
    try testing.expectEqual(Next{ .wait = .{
        .state = .pending,
        .run_at = .{ .after = .fromSeconds(60) },
        .scheduled_at = null,
        .attempt = 0,
        .unreadable_since = claimed,
    } }, d.next);
    try testing.expectEqualDeep(last(&r, .succeeded, null), d.last);
    try expectRows(&.{row(&r, .succeeded, null)}, &d);
    try testing.expect(d.event == .unreadable);
}
