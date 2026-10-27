//! Tests of the policy of a job type as the worker reads it: the attempts
//! of a record, the pauses between them, the errors that end them, and the
//! moments of a repeating job that a run stands for, skips or runs next.
//! `t0` is 2026-10-24T10:00:00Z.

const std = @import("std");
const testing = std.testing;
const Duration = std.Io.Duration;
const scheduler = @import("../root.zig");
const policy = @import("../worker/policy.zig");
const Policy = policy.Policy;
const Schedule = scheduler.Schedule;
const Instant = scheduler.Instant;
const Moment = scheduler.Store.Moment;

const t0: Instant = .fromUtc(2026, 10, 24, 10, 0, 0, .h24);

/// A one-shot job with the default policy, but the errors it gives up on.
const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        .retry = .{ .give_up_on = &.{ error.OrderGone, error.Fraud } },
    };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

/// A repeating job that sets every field of its declaration.
const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "nightly-cleanup",
        .timeout = .fromSeconds(600),
        .retry = .{ .attempts = 3, .delay = .fromSeconds(10), .multiplier = 2, .max_delay = .fromSeconds(60) },
        .repeat = .dailyAt(3, 30, 0, .am),
        .misfire = .{ .skip = .fromSeconds(15 * 60) },
        .history = .forever,
        .when_done = .{ .succeeded = .forever, .failed = .none },
    };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test "Policy.of takes the declaration of a job type" {
    const p: Policy = .of(NightlyCleanup);
    try testing.expectEqualStrings("nightly-cleanup", p.name);
    try testing.expectEqual(@as(?Duration, .fromSeconds(600)), p.timeout);
    try testing.expectEqual(@as(?u32, 3), p.retry.attempts);
    try testing.expectEqual(Duration.fromSeconds(10), p.retry.delay);
    try testing.expectEqual(@as(u32, 2), p.retry.multiplier);
    try testing.expectEqual(Duration.fromSeconds(60), p.retry.max_delay);
    try testing.expectEqual(scheduler.Misfire{ .skip = .fromSeconds(15 * 60) }, p.misfire);
    try testing.expect(p.history == .forever);
    try testing.expect(p.when_done.succeeded == .forever);
    try testing.expect(p.when_done.failed == .none);
    const repeat = p.repeat orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u17, 3 * 3600 + 30 * 60), repeat.internal.daily);

    const defaults: Policy = .of(SendInvoice);
    try testing.expectEqual(@as(?Duration, null), defaults.timeout);
    try testing.expectEqual(@as(?Schedule, null), defaults.repeat);
    try testing.expect(defaults.misfire == .coalesce);
    try testing.expect(defaults.history == .none);
}

test "attempts by the kind of record" {
    // null: 5 for a one-shot record, 1 for a repeating one.
    const p: Policy = .of(SendInvoice);
    try testing.expectEqual(@as(u32, 5), p.attempts(""));
    try testing.expectEqual(@as(u32, 1), p.attempts("daily 03:30:00"));
    // A number stays the number, whatever the record.
    const three: Policy = .of(NightlyCleanup);
    try testing.expectEqual(@as(u32, 3), three.attempts(""));
    try testing.expectEqual(@as(u32, 3), three.attempts("daily 03:30:00"));
}

test "retry pauses of 1 s, 5 s, 25 s and 120 s, each cut by up to 20 %" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    // The defaults: 1 s × 5^(k−1), at most 120 s, so 125 s is 120 s.
    const p: Policy = .of(SendInvoice);
    for ([_]i64{ 1, 5, 25, 120, 120 }, 1..) |seconds, k| try expectPauses(&p, @intCast(k), .fromSeconds(seconds), random);
    // multiplier 1: the same pause after every attempt.
    var constant = p;
    constant.retry.multiplier = 1;
    constant.retry.delay = .fromSeconds(3);
    for (1..6) |k| try expectPauses(&constant, @intCast(k), .fromSeconds(3), random);
    // max_delay caps the growth, and no k overflows it.
    var capped = p;
    capped.retry.delay = .fromMilliseconds(500);
    capped.retry.multiplier = 2;
    capped.retry.max_delay = .fromSeconds(2);
    try expectPauses(&capped, 1, .fromMilliseconds(500), random);
    try expectPauses(&capped, 2, .fromSeconds(1), random);
    try expectPauses(&capped, 3, .fromSeconds(2), random);
    try expectPauses(&capped, 4, .fromSeconds(2), random);
    try expectPauses(&capped, std.math.maxInt(u32), .fromSeconds(2), random);
    var huge = p;
    huge.retry.max_delay = .max;
    try expectPauses(&huge, std.math.maxInt(u32), .max, random);
}

/// 1000 pauses after the k-th attempt, each within 80–100 % of `full`, and
/// spread over that range: some near each end.
fn expectPauses(p: *const Policy, k: u32, full: Duration, random: std.Random) !void {
    const low = @divTrunc(full.nanoseconds, 5) * 4;
    var least: i96 = std.math.maxInt(i96);
    var most: i96 = 0;
    for (0..1000) |_| {
        const pause = p.retryDelay(k, random).nanoseconds;
        if (pause < low or pause > full.nanoseconds) {
            std.debug.print("k = {d}: a pause of {d} ns is outside {d}..{d}\n", .{ k, pause, low, full.nanoseconds });
            return error.TestUnexpectedResult;
        }
        least = @min(least, pause);
        most = @max(most, pause);
    }
    try testing.expect(least < @divTrunc(full.nanoseconds, 100) * 82);
    try testing.expect(most > @divTrunc(full.nanoseconds, 100) * 98);
}

test "givesUp names the errors of give_up_on" {
    const p: Policy = .of(SendInvoice);
    try testing.expect(p.givesUp(error.OrderGone));
    try testing.expect(p.givesUp(error.Fraud));
    try testing.expect(!p.givesUp(error.PaymentDeclined));
    try testing.expect(!p.givesUp(error.Timeout));
    const none: Policy = .of(NightlyCleanup);
    try testing.expect(!none.givesUp(error.OrderGone));
}

test "missed counts the moments between the plan and the claim, up to 10 000" {
    const minute: Schedule = .everyMinutes(1);
    try testing.expectEqual(@as(u32, 0), policy.missed(minute, t0, t0));
    try testing.expectEqual(@as(u32, 0), policy.missed(minute, t0, t0.add(.fromSeconds(30))));
    try testing.expectEqual(@as(u32, 2), policy.missed(minute, t0, t0.add(.fromSeconds(150))));
    // A claim at a moment of its own: this run stands for that moment too.
    try testing.expectEqual(@as(u32, 2), policy.missed(minute, t0, t0.add(.fromSeconds(120))));
    // Three hours of a schedule by the second: 10 800 moments, counted to
    // 10 000.
    try testing.expectEqual(@as(u32, 10_000), policy.missed(.everySeconds(1), t0, t0.add(.fromSeconds(3 * 3600))));
    // Times of day and cron, three days and an hour late.
    try testing.expectEqual(@as(u32, 3), policy.missed(.dailyAt(10, 0, 0, .am), t0, t0.add(.fromSeconds(3 * 86400 + 60))));
    try testing.expectEqual(@as(u32, 4), policy.missed(.cron("*/15 * * * *"), t0, t0.add(.fromSeconds(3600))));
    // A scheduled_at off the schedule (a run moved by the client) counts
    // the moments of the schedule after it.
    try testing.expectEqual(@as(u32, 1), policy.missed(minute, t0.add(.fromSeconds(10)), t0.add(.fromSeconds(70))));
    // fixedDelay has no moments of its own: its runs follow the ends of
    // runs.
    try testing.expectEqual(@as(u32, 0), policy.missed(.fixedDelay(.fromSeconds(30)), t0, t0.add(.fromSeconds(3600))));
}

test "late follows the skip threshold" {
    const skip: scheduler.Misfire = .{ .skip = .fromSeconds(15 * 60) };
    try testing.expect(!policy.late(skip, t0, t0));
    try testing.expect(!policy.late(skip, t0, t0.add(.fromSeconds(14 * 60))));
    // Late by the threshold itself is not later than it.
    try testing.expect(!policy.late(skip, t0, t0.add(.fromSeconds(15 * 60))));
    try testing.expect(policy.late(skip, t0, t0.add(.fromMilliseconds(15 * 60 * 1000 + 1))));
    try testing.expect(policy.late(skip, t0, t0.add(.fromSeconds(16 * 60))));
    // coalesce never skips, however late.
    try testing.expect(!policy.late(.coalesce, t0, t0.add(.fromSeconds(10 * 365 * 86400))));
}

test "nextRun comes after the claim" {
    // A moment of the claim itself is this run's, so the next is one later.
    try testing.expectEqual(@as(?Moment, .{ .at = t0.add(.fromSeconds(60)) }), policy.nextRun(.everyMinutes(1), t0));
    try testing.expectEqual(@as(?Moment, .{ .at = t0.add(.fromSeconds(60)) }), policy.nextRun(.everyMinutes(1), t0.add(.fromSeconds(59))));
    try testing.expectEqual(@as(?Moment, .{ .at = .fromUtc(2026, 10, 25, 3, 30, 0, .h24) }), policy.nextRun(.dailyAt(3, 30, 0, .am), t0));
    try testing.expectEqual(@as(?Moment, .{ .at = .fromUtc(2026, 10, 24, 10, 15, 0, .h24) }), policy.nextRun(.cron("*/15 * * * *"), t0));
    // fixedDelay: the store counts the delay from the transition.
    try testing.expectEqual(@as(?Moment, .{ .after = .fromSeconds(30) }), policy.nextRun(.fixedDelay(.fromSeconds(30)), t0));
    try testing.expectEqual(@as(?Moment, .{ .after = .fromMilliseconds(1500) }), policy.nextRun(.fixedDelay(.fromMilliseconds(1500)), t0));
    // No moment is left before the end of 9999.
    try testing.expectEqual(@as(?Moment, null), policy.nextRun(.everyMinutes(1), .fromUtc(9999, 12, 31, 23, 59, 30, .h24)));
}
