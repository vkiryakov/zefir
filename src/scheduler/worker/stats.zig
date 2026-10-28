//! `scheduler.Stats`, a snapshot of the counters of a worker, and the
//! counters themselves: atomics that any task of the worker bumps.

const std = @import("std");

/// The counters of a worker, as `worker.stats()` reads them; they count
/// from its start.
pub const Stats = struct {
    /// How many jobs the worker runs at once: `Options.workers`.
    workers: u16,
    /// The runs in flight now.
    running: u16,
    claimed: u64,
    succeeded: u64,
    /// Failed attempts: an error of the handler or a timeout.
    failed: u64,
    timed_out: u64,
    /// Jobs that ended `failed`: attempts spent, an error of
    /// `retry.give_up_on`, a record no instance read for
    /// `unreadable_limit`, a schedule without a next run.
    gave_up: u64,
    /// Runs stopped because their lease was taken over or could not be
    /// confirmed.
    lost: u64,
    /// Runs stopped because their record was removed (`client.cancel`).
    removed: u64,
    /// Claims of a record whose lease had expired in another claim.
    taken_over: u64,
    coalesced: u64,
    skipped: u64,
    /// Records given back because this instance could not read their
    /// payload or their schedule.
    unreadable: u64,
    /// Parked records found at the last start: the record of a declaration
    /// (the key "") of a job type that this code knows without `.repeat`.
    /// Only a worker that declares jobs looks for them: without any, its
    /// start does not touch the store.
    undeclared: u32,
    store_errors: u64,
    /// The last call of the store failed.
    store_down: bool,
};

/// The counters that only grow, by the names of their fields in `Stats`.
pub const Count = enum { claimed, succeeded, failed, timed_out, gave_up, lost, removed, taken_over, coalesced, skipped, unreadable, store_errors };

pub const Counters = struct {
    counts: std.EnumArray(Count, std.atomic.Value(u64)) = .initFill(.init(0)),
    running: std.atomic.Value(u16) = .init(0),
    undeclared: std.atomic.Value(u32) = .init(0),
    store_down: std.atomic.Value(bool) = .init(false),

    pub fn add(c: *Counters, count: Count, n: u64) void {
        _ = c.counts.getPtr(count).fetchAdd(n, .monotonic);
    }

    pub fn snapshot(c: *const Counters, workers: u16) Stats {
        var s: Stats = undefined;
        s.workers = workers;
        s.running = c.running.load(.monotonic);
        s.undeclared = c.undeclared.load(.monotonic);
        s.store_down = c.store_down.load(.monotonic);
        inline for (comptime std.enums.values(Count)) |count| @field(s, @tagName(count)) = c.counts.getPtrConst(count).load(.monotonic);
        return s;
    }
};
