//! `scheduler.testing.conformance`: the conformance suite of scheduler
//! stores. A store keeps the contract `scheduler.Store` when it passes it,
//! and then the scheduler works on it as on any other. S1–S22 check
//! records and their changes, claims and leases, finishes and the history,
//! retention, deadlines, lost replies, memory, and a mix of every operation
//! from 16 tasks, after which the invariants still hold.
//! `scheduler.MemoryStore` passes it in the tests of zefir-scheduler,
//! `mongo.SchedulerStore` against mongod; a store of your own runs it in
//! the tests of its package, against its server.
//!
//! ```zig
//! const Harness = struct {
//!     store: MyStore = undefined,
//!
//!     pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !scheduler.testing.conformance.Setup {
//!         h.store = try .init(gpa, io, .{ .database = "conformance" });
//!         return .{ .store = h.store.store(), .expiry_lag = .fromSeconds(10) };
//!     }
//!
//!     pub fn tearDown(h: *Harness, io: std.Io, setup: scheduler.testing.conformance.Setup) void {
//!         _ = setup;
//!         h.store.dropAll(io);
//!         h.store.deinit();
//!     }
//! };
//!
//! test "my store keeps the contract of the scheduler" {
//!     var harness: Harness = .{};
//!     var report = try scheduler.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
//!     defer report.deinit();
//!     if (report.failedCount() > 0) {
//!         std.debug.print("{f}", .{&report});
//!         return error.TestUnexpectedResult;
//!     }
//! }
//! ```
//!
//! The harness is a pointer to a type with these methods:
//!
//! - `setUp(h, io, gpa) !Setup`: the store, empty, and how long after its
//!   `expires_at` an expired record or row may still be there. The store
//!   takes its memory from `gpa`: the suite counts it, and memory left after
//!   `tearDown` fails the check as a leak.
//! - `tearDown(h, io, setup) void`: frees what `setUp` made and empties the
//!   store.
//! - optional `loseNextReply(h, io, op) !void`: the next call of `op`, a
//!   `scheduler.testing.Op`, reaches the store and is applied, and its reply
//!   is lost, as when a connection breaks after the request; of a `.claim`
//!   that takes three records, the reply of the second one. S17 needs it.
//!
//! `run` returns a report instead of failing through `std.testing`, so any
//! test runner can call it, also one that turns a panic into an exit code.
//! Each check runs on a fresh setup, in a task of its own: a check past its
//! time limit, 60 s, is canceled and fails. A check that needs a hook the
//! harness lacks is skipped, with the reason in the report. Leases in the
//! checks are 1 s or more, every wait is a loop on a clock, and times the
//! store writes are compared with its `now` within 1 s:
//! `Options.time_scale` stretches all of them, and the time limit, for a
//! slow machine or a remote store.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("../Store.zig");
const runner = @import("checks/runner.zig");

/// What a check gets from `harness.setUp`.
pub const Setup = struct {
    /// The store under test, without records or rows.
    store: Store,
    /// How long after its `expires_at` an expired record or row of the
    /// history may still be there: 0 for `MemoryStore`, the period of the
    /// TTL monitor and a margin for MongoDB (S13).
    expiry_lag: Io.Duration,
};

pub const Options = struct {
    /// Runs only these checks; null runs all of them.
    only: ?[]const Check = null,
    /// Stretches the leases, waits and tolerances of the checks and their
    /// time limit: raise it for a slow machine or a remote store.
    time_scale: u32 = 1,
};

/// The checks of table 6.7 of the design. Later releases may add checks,
/// so a `switch` over it needs an `else` branch.
pub const Check = enum {
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    s12,
    s13,
    s14,
    s15,
    s16,
    s17,
    s18,
    s19,
    s20,
    s21,
    s22,

    /// "S1" to "S22".
    pub fn label(check: Check) []const u8 {
        return switch (check) {
            inline else => |c| comptime "S" ++ @tagName(c)[1..],
        };
    }

    /// What the check proves, in a few words.
    pub fn title(check: Check) []const u8 {
        return switch (check) {
            .s1 => "create: created, existing leaves the record alone, replaced over a finished one with a new life; fields byte for byte",
            .s2 => "times: .after is the store's now and the duration, .at as it is, to the millisecond",
            .s3 => "get of a record and of none; remove is true, then false",
            .s4 => "update on life, revision and state; conflict, not_found; the rest left alone; pause, unpause and reset for claims",
            .s5 => "list: filters of job, tenant and state; pages of 7 over 50 records give each once",
            .s6 => "claim: due records of the listed jobs, at most max, the oldest first, running with owner, attempt and fence",
            .s7 => "claim never takes paused, finished, leased or future records",
            .s8 => "8 tasks claim 200 records at once: each exactly once",
            .s9 => "an expired lease is taken over: attempt and fence grow, took_over names the owner and its claimed_at",
            .s10 => "renew: the owner renews; another owner or fence is lost, a removed record removed, an expired lease renewed",
            .s11 => "finish: every kind of next, last null left alone, lost and changed, rows written after remove, pause_requested cleared",
            .s12 => "history: one row a claim, the owner's over abandoned; queries newest first, a page at a time",
            .s13 => "retention: expires_at is the store's now and the time; expired records and rows go within expiry_lag",
            .s14 => "next_in: how soon the nearest record the claim would take may be claimed; null when there is none",
            .s15 => "now is within tolerance of the claimed_at of a claim right after",
            .s16 => "less than 1 ms left is DeadlineExceeded and a cancelled token Cancelled, for every operation, nothing changed",
            .s17 => "lost replies of create, update, claim, renew and finish: a right answer or OutcomeUnknown, never a false one",
            .s18 => "limits: keys of 256 bytes, keys and tenants that look like MongoDB syntax, a 64 KiB payload, null fields",
            .s19 => "memory: results only from options.allocator and only during the call; requests not kept",
            .s20 => "16 tasks mix every operation for 3 s, and the invariants hold",
            .s21 => "the same owner and fence on a new life: the old claim's renew is removed, its finish lost",
            .s22 => "declared records (key \"\") go only to jobs of any_key; a parked one stays pending, out of next_in",
        };
    }
};

/// What came of one check.
pub const Outcome = union(enum) {
    passed,
    /// What went wrong, for people.
    failed: []const u8,
    /// Why the check did not run.
    skipped: []const u8,
};

/// What came of a run. It owns its strings: one `deinit`.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    /// `VTable.name` of the store of the setups.
    store_name: []const u8 = "",
    outcomes: std.EnumArray(Check, Outcome) = .initFill(.{ .skipped = "not run" }),

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }

    pub fn outcome(r: *const Report, check: Check) Outcome {
        return r.outcomes.get(check);
    }

    pub fn passedCount(r: *const Report) usize {
        return r.count(.passed);
    }

    pub fn failedCount(r: *const Report) usize {
        return r.count(.failed);
    }

    pub fn skippedCount(r: *const Report) usize {
        return r.count(.skipped);
    }

    fn count(r: *const Report, tag: std.meta.Tag(Outcome)) usize {
        var n: usize = 0;
        for (r.outcomes.values) |o| {
            if (o == tag) n += 1;
        }
        return n;
    }

    /// A line of totals, then one line a check: `{f}`.
    pub fn format(r: *const Report, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("scheduler conformance of \"{s}\": {d} passed, {d} failed, {d} skipped\n", .{
            r.store_name, r.passedCount(), r.failedCount(), r.skippedCount(),
        });
        for (std.enums.values(Check)) |check| {
            switch (r.outcome(check)) {
                .passed => try w.print("  passed   {s: <3}  {s}\n", .{ check.label(), check.title() }),
                .failed => |why| try w.print("  FAILED   {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
                .skipped => |why| try w.print("  skipped  {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
            }
        }
    }
};

/// `Canceled`: the caller's task was canceled; checked between checks.
pub const RunError = error{ OutOfMemory, Canceled };

/// Runs the checks, each on a fresh setup from `harness` and in a task of
/// its own, and reports what came of them. `gpa` must be thread-safe, such
/// as `std.testing.allocator`: stores allocate from the tasks that call
/// them. `io` must offer concurrency, as std's test `Io` and zio do: the
/// checks run calls in tasks of their own.
pub fn run(io: Io, gpa: Allocator, harness: anytype, options: Options) RunError!Report {
    const limit: Io.Duration = .fromSeconds(60 * @as(i64, @max(options.time_scale, 1)));
    return runner.runLimited(io, gpa, harness, options, limit);
}
