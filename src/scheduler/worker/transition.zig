//! The transition of a finished claim: what the record becomes, and what
//! its `last` and its history show, once the attempt of one claim ended. A
//! pure function of the ending, the record as the claim returned it, the
//! record as it is now when a change of the client came during the run,
//! and the policy of the job type; the worker sends the result to
//! `Store.finish` on condition of its claim.
//!
//! By the ending, for a one-shot and a repeating record alike unless said:
//!
//! - Success: a one-shot record is deleted or kept by `when_done`; a
//!   repeating one waits for the next moment of its plan after the claim.
//! - A failure or a timeout with attempts left, the error not in
//!   `give_up_on`: the retry pause, for the same run (its `scheduled_at`).
//! - Attempts spent or an error of `give_up_on`: a one-shot record is
//!   failed, kept or deleted by `when_done`; a repeating one goes on to its
//!   next moment.
//! - Stopped by the worker (a stop, a lease it could not confirm), or
//!   claimed and not started at a stop: back at once, the attempt not
//!   counted. Taken over or removed: the store refuses the transition, and
//!   only the row goes in.
//! - The abandoned attempt this claim took over was the last: no run; a
//!   one-shot record is failed, a repeating one goes on to its next moment,
//!   paused there when the client asked for a pause during that attempt.
//! - During the abandoned attempt this claim took over, the client moved
//!   the record (`reschedule`) to a moment still to come: no run, the
//!   record waits for it, attempt 0, even after the last attempt. Or it
//!   asked for a pause, and that attempt was not the last: no run, the
//!   record pauses for the same run, the attempt of this claim not counted.
//! - A repeating run later than its `.skip` threshold: no run, the next
//!   moment after the claim.
//! - A payload or a plan that does not read here: back in a minute, the
//!   attempt not counted, for an instance that reads it; failed once no
//!   instance read it for `unreadable_limit` in a row.
//! - No next moment within the search of a schedule: failed, `NoNextRun`.
//!
//! And for all of them:
//!
//! - A change of the client during the run wins over its outcome: a new
//!   moment (`reschedule`, which sets `attempt` 0) is where the record
//!   waits, and a new plan gives the next moment after the claim, without a
//!   retry; the outcome goes only to `last` and the history.
//! - `pause_requested` turns a wait into `paused`, with the same moment.
//! - A row of the history (when the job keeps one) and `last` tell of every
//!   attempt but two, where the handler did not run and there is nothing to
//!   tell: the return of a record that does not read here, and the return
//!   of one claimed and not started at a stop. The row of an abandoned
//!   attempt that the claim took over goes in whatever the claim did, with
//!   the attempt and the moment its own claim gave it: that attempt may
//!   have had effects, under the run key of that moment.
//! - Every transition but the return of a record that does not read here
//!   clears `unreadable_since`.

const std = @import("std");
const Duration = std.Io.Duration;
const Instant = @import("../Instant.zig");
const Schedule = @import("../schedule/Schedule.zig");
const Store = @import("../Store.zig");
const record = @import("../record.zig");
const policy = @import("policy.zig");
const Policy = policy.Policy;
const Record = record.Record;
const Run = record.Run;
const LastRun = record.LastRun;
const Retention = record.Retention;
const RunOutcome = record.RunOutcome;

/// How the attempt of one claim ended, as the worker saw it.
pub const Ending = union(enum) {
    /// `run` returned.
    succeeded,
    /// `run` returned this error.
    failed: anyerror,
    /// The `timeout` of the job type passed first.
    timed_out,
    /// The worker stopped the run and returns the record, the attempt not
    /// counted: at a stop, or when it could not confirm its lease.
    interrupted: enum { shutdown, lease_unconfirmed },
    /// A renewal said the claim was taken over: the finish writes the row,
    /// and the store refuses the transition.
    lost,
    /// A renewal said the record was removed, or is another life.
    removed,
    /// Claimed and not started at a stop: back, without a row, `last` kept.
    not_started,
    /// Not run: the payload or the plan does not read here.
    unreadable: enum { payload, schedule },
    /// Not run: a run of a repeating job later than its `.skip` threshold.
    skipped,
    /// Not run: the abandoned attempt this claim took over was the last.
    abandoned_last,
    /// Not run: the client moved the record during the abandoned attempt
    /// this claim took over, to a moment still to come.
    abandoned_moved,
    /// Not run: the client asked for a pause during the abandoned attempt
    /// this claim took over.
    abandoned_paused,
};

pub const Input = struct {
    policy: *const Policy,
    /// The record as the claim returned it.
    claimed: *const Record,
    took_over: ?Store.TookOver,
    ending: Ending,
    /// The record that a `changed` finish returned; null at the first try.
    current: ?*const Record = null,
    /// The owner of the claim, for its row.
    instance: []const u8,
    unreadable_limit: Duration,
    /// For the random cut of a retry pause.
    random: std.Random,
};

pub const Decision = struct {
    next: Store.Next,
    /// null leaves `last` as it is.
    last: ?LastRun,
    /// 0–2 rows: the abandoned attempt taken over, then this claim's.
    rows: [2]Run,
    rows_len: u2,
    keep: Retention,
    /// For stats and logs.
    event: enum { none, retry, gave_up, coalesced, skipped, unreadable, unreadable_gave_up, no_next_run },

    /// The rows to write before the transition.
    pub fn runs(d: *const Decision) []const Run {
        return d.rows[0..d.rows_len];
    }

    fn add(d: *Decision, run: Run) void {
        d.rows[d.rows_len] = run;
        d.rows_len += 1;
    }
};

/// How long a record waits that does not read here, for an instance that
/// reads it.
const unreadable_pause: Duration = .fromSeconds(60);

/// The transition of the claim of `input.claimed` after `input.ending`.
/// The store puts its own moment over `finished_at` of `last` and of the
/// rows; the decision leaves the moment of the claim there.
pub fn decide(input: Input) Decision {
    const r = input.claimed;
    const c = input.current orelse r;
    // A claimed record has its claimed_at; the plan's moment stands in for
    // a store that broke the contract.
    const claimed_at = r.claimed_at orelse r.scheduled_at;
    var d: Decision = .{ .next = .delete, .last = null, .rows = undefined, .rows_len = 0, .keep = input.policy.history, .event = .none };
    const told = toldOf(input.ending);
    if (input.policy.history != .none) {
        if (input.took_over) |prior| d.add(abandonedRow(r, prior, claimed_at));
        if (told) |t| d.add(ownRow(r, t, input.instance, claimed_at));
    }
    if (told) |t| d.last = .{ .outcome = t.outcome, .error_name = t.error_name, .attempt = r.attempt, .started_at = claimed_at, .finished_at = claimed_at };

    // `Patch.run_at` of the client sets attempt 0, which no claim leaves.
    const moved = input.current != null and c.attempt == 0;
    // A local first: the helpers below write `d.event` and `d.last`.
    const next: Store.Next = switch (input.ending) {
        // The store refuses these: the claim is not this owner's any more.
        .lost, .removed => back(r, .zero, null),
        .not_started, .interrupted => if (moved) movedTo(c, null) else back(r, .zero, null),
        .unreadable => |what| unreadable(input, &d, claimed_at, moved, what),
        .failed, .timed_out => failed: {
            if (moved) break :failed movedTo(c, null);
            const err = switch (input.ending) {
                .failed => |err| err,
                else => error.Timeout,
            };
            const replanned = input.current != null and !std.mem.eql(u8, c.plan, r.plan);
            const p = input.policy;
            if (!replanned and r.attempt < p.attempts(c.plan) and !p.givesUp(err)) {
                d.event = .retry;
                break :failed .{ .wait = .{
                    .state = .pending,
                    .run_at = .{ .after = p.retryDelay(r.attempt, input.random) },
                    .scheduled_at = r.scheduled_at,
                    .attempt = r.attempt,
                } };
            }
            break :failed over(input, &d, claimed_at, .failed);
        },
        .succeeded => if (moved) movedTo(c, null) else over(input, &d, claimed_at, .succeeded),
        .skipped => skipped: {
            if (!moved) break :skipped over(input, &d, claimed_at, .skipped);
            d.event = .skipped;
            break :skipped movedTo(c, null);
        },
        .abandoned_last => abandoned: {
            d.last = abandonedLast(input, claimed_at);
            if (moved) break :abandoned movedTo(c, null);
            break :abandoned over(input, &d, claimed_at, .abandoned);
        },
        // The record of the claim holds the moment of the move.
        .abandoned_moved => abandoned: {
            d.last = abandonedLast(input, claimed_at);
            break :abandoned movedTo(c, null);
        },
        .abandoned_paused => abandoned: {
            d.last = abandonedLast(input, claimed_at);
            break :abandoned if (moved) movedTo(c, null) else back(r, .zero, null);
        },
    };
    d.next = next;
    if (c.pause_requested) switch (d.next) {
        .wait => |*wait| wait.state = .paused,
        .done, .delete => {},
    };
    return d;
}

/// What a row and `last` tell of the attempt of this claim; null when the
/// handler did not run and there is nothing to tell.
const Told = struct { outcome: RunOutcome, error_name: ?[]const u8 };

fn toldOf(ending: Ending) ?Told {
    return switch (ending) {
        .succeeded => .{ .outcome = .succeeded, .error_name = null },
        .failed => |err| .{ .outcome = .failed, .error_name = @errorName(err) },
        .timed_out => .{ .outcome = .timed_out, .error_name = "Timeout" },
        .interrupted => |why| .{ .outcome = .interrupted, .error_name = switch (why) {
            .shutdown => "Shutdown",
            .lease_unconfirmed => "LeaseUnconfirmed",
        } },
        .lost => .{ .outcome = .interrupted, .error_name = "LeaseLost" },
        .removed => .{ .outcome = .interrupted, .error_name = "Cancelled" },
        .skipped => .{ .outcome = .skipped, .error_name = null },
        .not_started, .unreadable, .abandoned_last, .abandoned_moved, .abandoned_paused => null,
    };
}

/// `last` of the abandoned attempt that this claim took over and did not
/// follow with a run: started when its claim was made, at the attempt that
/// claim gave it, and ended with this claim.
fn abandonedLast(input: Input, claimed_at: Instant) LastRun {
    const prior = input.took_over orelse return .{ .outcome = .abandoned, .error_name = null, .attempt = input.claimed.attempt -| 1, .started_at = claimed_at, .finished_at = claimed_at };
    return .{ .outcome = .abandoned, .error_name = null, .attempt = prior.attempt, .started_at = prior.claimed_at, .finished_at = claimed_at };
}

fn ownRow(r: *const Record, told: Told, instance: []const u8, claimed_at: Instant) Run {
    return .{
        .job = r.job,
        .key = r.key,
        .tenant = r.tenant,
        .life = r.life,
        .fence = r.fence,
        .attempt = r.attempt,
        .scheduled_at = r.scheduled_at,
        .started_at = claimed_at,
        .finished_at = claimed_at,
        .outcome = told.outcome,
        .error_name = told.error_name,
        .instance = instance,
        .expires_at = null,
    };
}

/// The row of the attempt before this claim, whose owner was lost: the
/// claim before, started when it was made, at the attempt and the moment
/// that claim gave its run, which a move of the client since left.
fn abandonedRow(r: *const Record, prior: Store.TookOver, claimed_at: Instant) Run {
    return .{
        .job = r.job,
        .key = r.key,
        .tenant = r.tenant,
        .life = r.life,
        .fence = r.fence -| 1,
        .attempt = prior.attempt,
        .scheduled_at = prior.scheduled_at,
        .started_at = prior.claimed_at,
        .finished_at = claimed_at,
        .outcome = .abandoned,
        .error_name = null,
        .instance = prior.owner,
        .expires_at = null,
    };
}

/// The record back for the same run after `pause`, this attempt not
/// counted.
fn back(r: *const Record, pause: Duration, unreadable_since: ?Instant) Store.Next {
    return .{ .wait = .{
        .state = .pending,
        .run_at = .{ .after = pause },
        .scheduled_at = r.scheduled_at,
        .attempt = r.attempt -| 1,
        .unreadable_since = unreadable_since,
    } };
}

/// The record waits for the moment that the client set during the run.
fn movedTo(c: *const Record, unreadable_since: ?Instant) Store.Next {
    return .{ .wait = .{ .state = .pending, .run_at = .{ .at = c.scheduled_at }, .scheduled_at = null, .attempt = 0, .unreadable_since = unreadable_since } };
}

/// Finished and kept by `keep`, or deleted when it keeps nothing.
fn done(state: record.State, keep: Retention) Store.Next {
    return switch (keep) {
        .none => .delete,
        .keep_for, .forever => .{ .done = .{ .state = state, .keep = keep } },
    };
}

/// A record that did not read here goes back in a minute, without counting
/// the attempt, until no instance read it for `unreadable_limit` from the
/// first that could not: then it is failed.
fn unreadable(input: Input, d: *Decision, claimed_at: Instant, moved: bool, what: @FieldType(Ending, "unreadable")) Store.Next {
    const r = input.claimed;
    const since = r.unreadable_since orelse claimed_at;
    d.event = .unreadable;
    if (moved) return movedTo(input.current orelse r, since);
    const unread_ns = (@as(i128, claimed_at.unix_ms) - since.unix_ms) * std.time.ns_per_ms;
    if (unread_ns < input.unreadable_limit.nanoseconds) return back(r, unreadable_pause, since);
    d.event = .unreadable_gave_up;
    d.last = .{
        .outcome = .failed,
        .error_name = switch (what) {
            .payload => "UnreadablePayload",
            .schedule => "UnreadableSchedule",
        },
        .attempt = r.attempt,
        .started_at = claimed_at,
        .finished_at = claimed_at,
    };
    return done(.failed, input.policy.when_done.failed);
}

/// The run is over and no retry follows: a one-shot record finishes by
/// `when_done`, a repeating one waits for the next moment of its plan
/// after the claim.
fn over(input: Input, d: *Decision, claimed_at: Instant, how: enum { succeeded, failed, skipped, abandoned }) Store.Next {
    const c = input.current orelse input.claimed;
    const p = input.policy;
    if (c.plan.len == 0) {
        if (how == .succeeded) return done(.succeeded, p.when_done.succeeded);
        d.event = .gave_up;
        return done(.failed, p.when_done.failed);
    }
    const s = Schedule.parse(c.plan, null) catch {
        // A plan this instance does not know, written during the run by a
        // newer version: back in a minute for an instance that knows it.
        d.event = .unreadable;
        return .{ .wait = .{
            .state = .pending,
            .run_at = .{ .after = unreadable_pause },
            .scheduled_at = null,
            .attempt = 0,
            .unreadable_since = input.claimed.unreadable_since orelse claimed_at,
        } };
    };
    const moment = policy.nextRun(s, claimed_at) orelse {
        d.event = .no_next_run;
        d.last = .{ .outcome = .failed, .error_name = "NoNextRun", .attempt = input.claimed.attempt, .started_at = claimed_at, .finished_at = claimed_at };
        return done(.failed, p.when_done.failed);
    };
    // A run that came after the next moment of its plan stood for it too.
    // An abandoned last attempt runs nothing here, so it stands for none.
    const first = s.next(input.claimed.scheduled_at);
    d.event = switch (how) {
        .skipped => .skipped,
        .abandoned => .none,
        .succeeded, .failed => if (first != null and first.?.unix_ms <= claimed_at.unix_ms) .coalesced else .none,
    };
    return .{ .wait = .{ .state = .pending, .run_at = moment, .scheduled_at = null, .attempt = 0 } };
}
