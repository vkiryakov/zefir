//! The policy of a job type as the worker reads it: how many attempts a
//! record has, the pause before each retry, the errors that end the
//! attempts, and the moments of a repeating job: how many a run stands
//! for, whether it came too late to run, and which one is next.

const std = @import("std");
const Duration = std.Io.Duration;
const Instant = @import("../Instant.zig");
const Schedule = @import("../schedule/Schedule.zig");
const Store = @import("../Store.zig");
const job_type = @import("../Job.zig");
const Retention = @import("../record.zig").Retention;

/// What the worker reads of the declaration of a job type.
pub const Policy = struct {
    name: []const u8,
    timeout: ?Duration,
    retry: job_type.Retry,
    misfire: job_type.Misfire,
    history: Retention,
    when_done: job_type.WhenDone,
    repeat: ?Schedule,

    /// The policy of the job type `J`; the compiler checks `J`.
    pub fn of(comptime J: type) Policy {
        job_type.assertJob(J);
        const job = J.scheduler_job;
        return .{
            .name = job.name,
            .timeout = job.timeout,
            .retry = job.retry,
            .misfire = job.misfire,
            .history = job.history,
            .when_done = job.when_done,
            .repeat = job.repeat,
        };
    }

    /// The attempts of a record in all: `retry.attempts`, or by default 5
    /// for a one-shot record (`plan` "") and 1 for a repeating one, whose
    /// next run plays the retry.
    pub fn attempts(p: *const Policy, plan: []const u8) u32 {
        return p.retry.attempts orelse if (plan.len == 0) 5 else 1;
    }

    /// The pause after the k-th failed attempt, k from 1: `delay ×
    /// multiplier^(k−1)`, at most `max_delay`, and shorter by a random 0–20
    /// %, so that jobs that failed together come back apart.
    pub fn retryDelay(p: *const Policy, k: u32, random: std.Random) Duration {
        const most = p.retry.max_delay.nanoseconds;
        var ns = p.retry.delay.nanoseconds;
        if (p.retry.multiplier > 1) {
            var i: u32 = 1;
            while (i < k and ns < most) : (i += 1) ns *|= @as(i96, p.retry.multiplier);
        }
        ns = @min(ns, most);
        const cut = @divTrunc(@as(i128, ns) * random.uintAtMost(u32, cut_parts), 5 * cut_parts);
        return .fromNanoseconds(ns - @as(i96, @intCast(cut)));
    }

    /// Whether `err` ends the attempts: it is one of `retry.give_up_on`.
    pub fn givesUp(p: *const Policy, err: anyerror) bool {
        for (p.retry.give_up_on) |e| {
            if (e == err) return true;
        }
        return false;
    }
};

/// The steps of the random cut of a pause: a fifth of the pause in a
/// million parts.
const cut_parts = 1_000_000;

/// `missed` counts no further.
const max_missed = 10_000;

/// The moments of `s` after `scheduled_at` and up to `claimed_at`: the runs
/// that the run of this claim stands for, at most 10 000; 0 for
/// `fixedDelay`, whose runs follow the ends of runs.
pub fn missed(s: Schedule, scheduled_at: Instant, claimed_at: Instant) u32 {
    var count: u32 = 0;
    var after = scheduled_at;
    while (count < max_missed) : (count += 1) {
        const moment = s.next(after) orelse break;
        if (moment.unix_ms > claimed_at.unix_ms) break;
        after = moment;
    }
    return count;
}

/// Whether a run of a repeating job came later than its `.skip` threshold
/// allows, and so does not run; `.coalesce` runs however late. One-shot
/// records never skip: ask only for a repeating one.
pub fn late(misfire: job_type.Misfire, scheduled_at: Instant, claimed_at: Instant) bool {
    return switch (misfire) {
        .coalesce => false,
        .skip => |threshold| (@as(i128, claimed_at.unix_ms) - scheduled_at.unix_ms) * std.time.ns_per_ms > threshold.nanoseconds,
    };
}

/// The run of a repeating job after a claim: the first moment of `s`
/// strictly after `claimed_at`, by the store's clock, or for `fixedDelay`
/// its delay after the transition, which the store counts. null: no moment
/// within the search of `Schedule.next` (9 years, and the end of 9999).
pub fn nextRun(s: Schedule, claimed_at: Instant) ?Store.Moment {
    return switch (s.internal) {
        .delay => |ms| .{ .after = .fromMilliseconds(@intCast(ms)) },
        else => .{ .at = s.next(claimed_at) orelse return null },
    };
}
