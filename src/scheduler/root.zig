//! zefir-scheduler — jobs that an application puts on a time and that
//! several instances of a service run. Its import name is `scheduler`, and
//! in the umbrella module it is `zefir.scheduler`.
//!
//! A job is a Zig type: a declaration `pub const scheduler_job:
//! scheduler.Job`, the data of one run, `pub const Payload`, and a method
//! `run`. `scheduler.Client` puts jobs on a time by a key, one for an
//! order, a customer or a tenant: once (`.at`, `.after`) or again and
//! again (ready-made schedules, cron, a fixed delay after each run); it
//! cancels, pauses, moves and retries them and shows their history.
//! `scheduler.Worker(Jobs)` claims the jobs that are due, atomically, only
//! of the types it knows and no more than it has free slots; it holds a
//! lease on each job while the job runs and records the outcome. The store
//! is the public contract `scheduler.Store`: `scheduler.MemoryStore` keeps
//! jobs in memory (each instance on its own, nothing survives a restart),
//! `mongo.SchedulerStore` of zefir-mongo in MongoDB. The promise is "at
//! least once": after a failure a job may run twice, so a handler keeps
//! its effects idempotent by the run key and the claim number that its
//! context gives it.
//!
//! How a service uses it:
//!
//! 1. Start: build a store, a `scheduler.Client` and a
//!    `scheduler.Worker(Jobs)` with pointers to the jobs; `Worker.start`
//!    writes the repeating jobs that the code declares and starts polling.
//! 2. Scheduling: `client.schedule(io, ctx, SendInvoice, .{ .key =
//!    "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = … },
//!    .{})`; the compiler checks the payload against `SendInvoice.Payload`,
//!    and a key already taken answers `.existing`.
//! 3. Running: the worker polls every second, claims no more jobs than it
//!    has free slots, runs each one's `run` in a task of its own, renews
//!    the lease every 20 s and records the outcome on condition of its
//!    claim.
//! 4. A lost instance: nobody renews its leases, so 60 s later by the
//!    store's clock another instance claims its jobs; the attempt counts,
//!    and the history shows it as abandoned.
//! 5. Shutdown: the worker stops claiming, gives the running jobs
//!    `shutdown_grace`, cancels the rest and gives them back to the store.
//!
//! Times are moments of UTC (`scheduler.Instant`). Schedules
//! (`scheduler.Schedule`) are values without allocation; the compiler
//! checks one whose arguments it knows, and a call that takes one checks
//! the rest.

const std = @import("std");
const calendar = @import("schedule/calendar.zig");
const record = @import("record.zig");

pub const Diagnostics = @import("Diagnostics.zig");
pub const Instant = @import("Instant.zig");
pub const Schedule = @import("schedule/Schedule.zig");
pub const HourFormat = calendar.HourFormat;
pub const Weekday = calendar.Weekday;

pub const Ref = record.Ref;
pub const CallOptions = record.CallOptions;
pub const ListFilter = record.ListFilter;
pub const HistoryFilter = record.HistoryFilter;
pub const Page = record.Page;
pub const RecordPage = record.RecordPage;
pub const RunPage = record.RunPage;
pub const State = record.State;
pub const RunOutcome = record.RunOutcome;
pub const Life = record.Life;
pub const Retention = record.Retention;
pub const Record = record.Record;
pub const LastRun = record.LastRun;
pub const Run = record.Run;

/// The store contract: `scheduler.MemoryStore`, `mongo.SchedulerStore` or a
/// store of your own behind one interface.
pub const Store = @import("Store.zig");
pub const StoreError = Store.StoreError;
pub const Error = Store.Error;
pub const Outcome = Store.Outcome;
pub const outcome = Store.outcome;
/// A store in the memory of the process: for one instance, for tests, and
/// for jobs that each instance runs on its own.
pub const MemoryStore = @import("MemoryStore.zig");
/// For tests of workers and applications: `testing.FaultyStore` fails any
/// store on demand.
pub const testing = @import("testing.zig");

/// When to run a job.
pub const When = union(enum) {
    /// Once, at this moment; a moment already past runs at once.
    at: Instant,
    /// Once, this long after the store took the job, by the store's clock.
    /// A negative one is `error.InvalidArgument`.
    after: std.Io.Duration,
    /// Again and again, by the schedule.
    repeat: Schedule,
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("signature.zig");
    _ = @import("tests/diagnostics_tests.zig");
    _ = @import("tests/instant_tests.zig");
    _ = @import("tests/schedule_tests.zig");
    _ = @import("tests/cron_tests.zig");
    _ = @import("tests/record_tests.zig");
    _ = @import("tests/store_tests.zig");
    _ = @import("tests/memory_store_tests.zig");
    _ = @import("tests/memory_load_tests.zig");
    _ = @import("tests/faulty_store_tests.zig");
}
