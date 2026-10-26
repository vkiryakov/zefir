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

pub const Diagnostics = @import("Diagnostics.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests/diagnostics_tests.zig");
}
