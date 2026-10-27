# scheduler

**Jobs that a Zig service puts on a time, and that any of its instances
runs.** A shop sends the invoice of an order a minute after the order,
reminds a customer of an unpaid order three days later, and cleans up
every night at 3:30. zefir-scheduler keeps such *jobs* in a *store*, and
every instance of the service runs a *worker* that takes the jobs that are
due, one instance a job, and runs them. A job is a plain Zig type with a
method `run`; its data, the *payload*, is a struct that the compiler
checks when you put the job on its time, and a schedule such as
`.dailyAt(3, 30, 0, .am)` or a cron expression is checked when the
program compiles. The store keeps everything: the jobs outlive a restart
of the service, an instance that crashes leaves its jobs to the others,
and a job that fails tries again. It is written against `std.Io` only,
runs on [zio](https://github.com/lalinsky/zio) in production, and keeps
its jobs in memory or in MongoDB.

> [!IMPORTANT]
> **Not in v1 (TODO):**
>
> - **Time zones** and their changes of the clock in summer: every time is
>   UTC.
> - **Two runs of one repeating job at once, and a queue of its runs**: a
>   run that outlasts its period delays the next one, see
>   [Missed runs](#missed-runs).
> - **Catching up every missed run** of a repeating job: one run stands
>   for those it missed, or a late one is skipped.
> - **The cron of `? L W # H`, a year and `a/n`**, and the last day of a
>   month in `monthlyOn`.
> - **Metrics, an exporter, a web panel, a span for each run**:
>   `worker.stats()` takes snapshots.
> - **Tenants in databases of their own**: a tenant is a field of a job
>   and a filter of the lists.
> - **Stores on Redis and Postgres**: a store of your own works once it
>   passes the conformance suite, see
>   [A store of your own](#a-store-of-your-own).
> - **Keeping the last N runs**: the history keeps its rows for a time.
> - **Priorities of jobs, and limits on the running jobs of a type.**
> - **Chains and graphs of jobs.**
> - **A cancel or a wake-up that reaches the other instances at once**
>   (MongoDB's change streams): a run in another instance stops at its
>   next renewal of the lease, within `renew_every`.
> - **Several jobs claimed in one request to MongoDB**: one
>   `findAndModify` for each.
> - **A method that runs a job now**: `reschedule` with `.after = .zero`
>   does it.
> - **`wtimeout` and read concerns in zefir-mongo**, which come with
>   replica sets.

## Contents

1. [What the scheduler does](#what-the-scheduler-does)
2. [Installation](#installation)
3. [Quick start](#quick-start)
4. [Jobs](#jobs)
5. [When jobs run](#when-jobs-run)
6. [Jobs by key](#jobs-by-key)
7. [Failures and retries](#failures-and-retries)
8. [Several instances](#several-instances)
9. [Missed runs](#missed-runs)
10. [History and retention](#history-and-retention)
11. [MongoDB](#mongodb)
12. [Under zefir.App](#under-zefirapp)
13. [Shutdown and failures of the store](#shutdown-and-failures-of-the-store)
14. [Logs and statistics](#logs-and-statistics)
15. [Tests of your jobs](#tests-of-your-jobs)
16. [A store of your own](#a-store-of-your-own)

Programs that `zig build e2e` in `tests/scheduler` builds and runs against
mongod, checking what they print against this guide:
[quick start on MongoDB](mongo_quick_start.zig) ·
[instances](instances.zig).

## MongoDB

`scheduler.MemoryStore` keeps the jobs of one process: they go with it,
and another instance never sees them. A service that runs in several
instances keeps its jobs in MongoDB: `mongo.SchedulerStore` of
zefir-mongo implements the store contract, so the client, the worker and
the jobs are the same as on memory. Every instance builds its own store
on its own `mongo.Client`, and they all share its two collections.

> [!WARNING]
> **No TLS yet: use it only in a network you trust.** zefir-mongo speaks
> plain TCP, see [its guide](../../mongo/examples/README.md). The payloads
> of the jobs travel unencrypted.

`mongo.SchedulerStore.init(gpa, io, &mongo_client, options)` checks the
names and does no I/O; the client of MongoDB must outlive the store, and
the store stays where it is once `store()` gave it out. The options:

| Option | Default | What it is |
|---|---|---|
| `database` | — | the database of the two collections |
| `jobs` | `"scheduler_jobs"` | the collection of the jobs, a document each |
| `runs` | `"scheduler_runs"` | the collection of the history, a row each |
| `write_concern` | `.{ .journal = true }` | the write concern of every write, see below |
| `start_timeout` | 10 s | how long `start` under zefir.App waits for the indexes |
| `diagnostics` | null | a `mongo.Diagnostics` that says why `init`, `ensureIndexes` or `start` failed |

One pair of collections serves one service. Two services that share it
and a name of a job would run each other's jobs, and fight over the
record of a declared one.

### The quick start on MongoDB

The quick start again, on MongoDB: the shop sends the invoice of order 42
a second after the order. The program connects, makes the indexes of the
store, starts a worker, puts the invoice on its time, waits for the run,
stops the worker, and reads what the store kept:

```zig
//! The quick start on MongoDB: the shop sends the invoice of an order a
//! second after the order, through `mongo.SchedulerStore`, the store that
//! all the instances of the shop share. It connects, makes the indexes of
//! the store, starts a worker, puts the invoice of order 42 on its time,
//! waits for the run, stops the worker, and reads what the store kept of
//! the job. Each run starts from empty collections.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/scheduler, `zig build example-mongo_quick_start` runs it
//! against the servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const scheduler = @import("scheduler");
const zio = @import("zio");
const bson = @import("mongo-bson");

/// The worker and the store log through std.log; this sends their records
/// to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        /// Kept out of the URI, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// The job: the invoice of an order. What it needs is in its fields: here
/// the logger, in a shop the client of its billing service.
const SendInvoice = struct {
    app: log.Logger,
    /// How many invoices went out: main waits for the first.
    sent: std.atomic.Value(u32) = .init(0),

    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        // A row of history for each run, kept for 30 days.
        .history = .{ .keep_for = .fromSeconds(30 * 24 * 60 * 60) },
    };

    /// The data of one run: the store keeps it as JSON.
    pub const Payload = struct { order_id: u64, amount_cents: u64 };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
        self.app.info("Invoice sent", .{ .order = payload.order_id, .amount_cents = payload.amount_cents, .attempt = ctx.info().attempt });
        _ = self.sent.fetchAdd(1, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    // The logger outlives the runtime, so it takes `init.io`, through which
    // the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the program; the client of MongoDB, the store and
    // the worker run on its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var mongo_client: mongo.Client = try .init(init.gpa, io, .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    defer mongo_client.deinit();
    var diagnostics: mongo.Diagnostics = .{};
    mongo_client.connect(io, within(io, .fromSeconds(10)), &diagnostics) catch |err| {
        app.err("Cannot connect", .{ .reason = err, .details = diagnostics.message() });
        return err;
    };
    defer mongo_client.close(io);
    app.info("Connected", .{});
    try startAfresh(io, init.gpa, &mongo_client);

    // The store: the collections scheduler_jobs and scheduler_runs of the
    // database shop. ensureIndexes makes their indexes and measures the
    // clock of the server, by which the store keeps every time.
    var store: mongo.SchedulerStore = try .init(init.gpa, io, &mongo_client, .{ .database = "shop" });
    defer store.deinit();
    try store.ensureIndexes(io, within(io, .fromSeconds(10)));

    // The client puts jobs on their time; the worker runs them.
    const client: scheduler.Client = .init(init.gpa, io, store.store(), .{});
    var invoices: SendInvoice = .{ .app = app };
    var worker: scheduler.Worker(struct { invoices: *SendInvoice }) = try .init(init.gpa, io, store.store(), .{ .invoices = &invoices }, .{ .instance = "shop" });
    defer worker.deinit(io);
    try worker.start(io);

    const scheduled = try client.schedule(io, within(io, .fromSeconds(5)), SendInvoice, .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(1) },
        .payload = .{ .order_id = 42, .amount_cents = 1999 },
    }, .{});
    app.info("Scheduled", .{ .job = SendInvoice.scheduler_job.name, .key = "order-42", .result = scheduled });

    // The invoice goes out about a second from now: wait for it, for 10 s
    // at most.
    var waited: u32 = 0;
    while (invoices.sent.load(.acquire) == 0) : (waited += 1) {
        if (waited == 100) return error.InvoiceNotSent;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    // The worker stops claiming, and returns once the run has written its
    // outcome, within 10 s.
    try worker.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }));

    // The job succeeded: its record went, and the history keeps its run.
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = within(io, .fromSeconds(5));
    const record = try client.get(io, ctx, .of(SendInvoice, "order-42"), arena, .{});
    app.info("Record", .{ .found = record != null });
    const history = try client.history(io, ctx, .{ .job = SendInvoice.scheduler_job.name, .key = "order-42" }, .{}, arena, .{});
    for (history.runs) |run| app.info("Run", .{
        .outcome = run.outcome,
        .attempt = run.attempt,
        .fence = run.fence,
        .instance = run.instance,
        .scheduled_at = run.scheduled_at,
        .started_at = run.started_at,
        .finished_at = run.finished_at,
    });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Drops the collections of the store, so that the history shows only
/// this run.
fn startAfresh(io: std.Io, gpa: std.mem.Allocator, mongo_client: *mongo.Client) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(mongo_client, "shop", &ids);
    const op: mongo.OperationContext = .of(within(io, .fromSeconds(10)));
    for ([_][]const u8{ "scheduler_jobs", "scheduler_runs" }) |name|
        try db.collection(name).drop(io, op, .{ .allocator = arena_state.allocator() });
}
```

Start a mongod as in [Installation](#installation), then the program:

```text
$ zig build run
2026-10-27T14:00:36.352Z INFO  [app] Connected
2026-10-27T14:00:36.368Z INFO  [scheduler] 1 job type, 10 workers, instance shop/c9a0bd9d75226b98bb9791730bdbf884
2026-10-27T14:00:36.372Z INFO  [app] Scheduled job=send-invoice key=order-42 result=created
2026-10-27T14:00:37.377Z INFO  [app] Invoice sent order=42 amount_cents=1999 attempt=1
2026-10-27T14:00:37.380Z INFO  [scheduler] stopping
2026-10-27T14:00:37.380Z INFO  [scheduler] stopped
2026-10-27T14:00:37.381Z INFO  [app] Record found=false
2026-10-27T14:00:37.382Z INFO  [app] Run outcome=succeeded attempt=1 fence=1 instance=shop/c9a0bd9d75226b98bb9791730bdbf884 scheduled_at=2026-10-27T14:00:37.371Z started_at=2026-10-27T14:00:37.374Z finished_at=2026-10-27T14:00:37.377Z
```

What is new next to [the quick start](#quick-start):

- **The client of MongoDB.** `mongo.Client` connects under a deadline,
  with the password of `confy.Secret` kept out of the connection string;
  its [guide](../../mongo/examples/README.md) has the rest. The program
  runs on zio, `rt.io()`, as a service does.
- **The indexes.** `ensureIndexes` makes the indexes of both collections
  (one that is there is no error) and measures the clock of the server,
  under its deadline. Without zefir.App a program calls it once at the
  start; under App, the store's `start` does it, see
  [Under zefir.App](#under-zefirapp).
- **The times are the server's.** Every write that sets a time takes
  `$$NOW` of the server, so the instances agree on what is due whatever
  their own clocks say: the `scheduled_at` of the run is a second after
  the server took the job, and its `started_at` when the server gave it
  to the worker. `store.now(io)` estimates that clock without I/O, from
  the clock of the process and an offset that `ensureIndexes` measured
  and every reply with the server's time refines.
- **What stays.** The job succeeded, and a succeeded job leaves no record
  by default, so `get` finds none. The history keeps a row for each claim
  of a job that asks for it, here for 30 days: the first claim of this
  record, `fence=1`, by the worker `shop/…`, the name of the instance with
  32 random hex digits, new at each start.

### What the collections hold

A job is one document of `scheduler_jobs`, whose `_id` is its job and its
key, so a key is taken once:

```text
{
  _id: "send-invoice/order-42",        <job>/<key>; a declared job has "nightly-cleanup/"
  job: "send-invoice", key: "order-42",
  tenant: "acme",                      left out without a tenant
  life: "9f1c0e5b2d41a8c6e9f0b1d2a3c4e5f6",   new when the key is scheduled again
  plan: "",                            "" once; a schedule as text: "daily 03:30:00"
  payload: "{\"order_id\":42,\"amount_cents\":1999}",   the JSON, byte for byte
  state: "pending",                    pending, running, paused, succeeded, failed
  scheduled_at: Date, run_at: Date,
  wake_at: Date,                       when it may be claimed: run_at, or lease_until when running
  attempt: 0, fence: 0, revision: 0,
  owner: "shop/7f3a…", claimed_at: Date, lease_until: Date,   while it runs
  last: { outcome, error, attempt, started_at, finished_at },   the last run
  created_at: Date, updated_at: Date,
  finished_at: Date, expires_at: Date  when it is finished and kept
}
```

and each row of the history is one document of `scheduler_runs`, whose
`_id` is the life of the job and the number of the claim:
`{ _id: "<life>/<fence>", job, key, tenant, life, fence, attempt,
scheduled_at, started_at, finished_at, outcome, error, instance,
expires_at }`. A field without a value is left out, and every string of
yours goes into a pipeline as a `$literal`: a key such as `$set` or
`a.b` is a key, never an operator or a path. The indexes, which
`ensureIndexes` makes:

| Collection | Index | Keys | What for |
|---|---|---|---|
| jobs | `_id` | `"<job>/<key>"` | one document a job: `get`, changes, renewals, outcomes; `list` in its order |
| jobs | `scan` | `{job: 1, wake_at: 1}`, of the documents with `wake_at` | claims: the due jobs of the worker's types, the oldest first, and how soon the next one is due |
| jobs | `expire` | `{expires_at: 1}`, a TTL index | finished jobs kept for a time |
| jobs | `tenant` | `{tenant: 1, _id: 1}`, of the documents with a tenant | `list` by tenant |
| runs | `job_key_finished` | `{job: 1, key: 1, finished_at: -1}` | the history of one job, the newest first |
| runs | `job_finished` | `{job: 1, finished_at: -1}` | the history of a type of job |
| runs | `tenant_finished` | `{tenant: 1, finished_at: -1}`, of the rows with a tenant | the history of a tenant |
| runs | `expire` | `{expires_at: 1}`, a TTL index | rows kept for a time |

MongoDB's TTL monitor wakes once a minute and promises no exact time: a
finished job or a row may live a minute past its `expires_at`. Leases are
never its business: whether a lease ran out, the claim asks the server's
clock.

### Durable writes

Every write of the store goes with `write_concern`, `{w: 1, j: true}` by
default: mongod answers once the change is in its journal on disk. Without
`j`, a standalone mongod answers once the change is in its memory, and a
hard crash of the server between two flushes of the journal (100 ms
apart) loses changes that it confirmed: a job scheduled, or the outcome of
a run, which would then run again. `j` costs a flush of the journal for
each write; `.{ .journal = false }` trades that for speed. A reply with a
`writeConcernError` means the write ran without that promise: the store
reads the job back, returns the result as usual, and logs a warning with
the server's code. [Durable writes](../../mongo/examples/README.md#durable-writes)
in the guide of zefir-mongo has the rest.

### MongoDB 7.0

The store works on MongoDB 7.0 and later; its end-to-end tests run on
7.0.45 and 9.0.4. A claim compares the time of a job with `$$NOW`, the
clock of the server, and MongoDB 7.0 uses no index for such a comparison.
So the filter of a claim also holds a plain range, `wake_at` up to the
store's estimate of the server's clock plus 2 s, which the index `scan`
serves on every version, next to the exact comparison with `$$NOW`. The
range never decides what a claim takes; a poor estimate costs a delay or
a few more documents read, never a wrong claim.

### Several instances on one store

In production each instance is a process of its own, with its own client
of MongoDB, store and worker. `instances.zig` puts three workers in one
process on one store, which is all the same to MongoDB, and schedules the
invoices of 30 orders:

```zig
//! Three instances of the shop on one store in MongoDB. In production each
//! instance is a process of its own, with its own client of MongoDB, store
//! and worker; here three workers in one process share one store, which is
//! all the same to MongoDB. The shop puts the invoices of 30 orders on
//! their time. Each worker claims due jobs as its slots free up, and a
//! claim is atomic: every invoice goes out once, whichever instance sends
//! it. Which one sends which changes from run to run, so the program
//! counts the invoices, not who sent them. Each run starts from empty
//! collections.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/scheduler, `zig build example-instances` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const scheduler = @import("scheduler");
const zio = @import("zio");
const bson = @import("mongo-bson");

/// The worker and the store log through std.log; this sends their records
/// to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        /// Kept out of the URI, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

const orders = 30;
const instances = 3;

/// The billing service, which the invoices go to; here it only counts
/// them, by the number of the order.
const Billing = struct {
    sent: [orders + 1]std.atomic.Value(u32) = @splat(.init(0)),
    total: std.atomic.Value(u32) = .init(0),

    fn send(b: *Billing, order_id: u32) error{UnknownOrder}!void {
        if (order_id == 0 or order_id > orders) return error.UnknownOrder;
        _ = b.sent[order_id].fetchAdd(1, .acq_rel);
        _ = b.total.fetchAdd(1, .acq_rel);
    }
};

/// The job: the invoice of an order, sent to the billing service.
const SendInvoice = struct {
    billing: *Billing,

    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        // A row of history for each run, kept for 30 days.
        .history = .{ .keep_for = .fromSeconds(30 * 24 * 60 * 60) },
    };

    pub const Payload = struct { order_id: u32, amount_cents: u64 };

    pub fn run(self: *SendInvoice, _: *scheduler.Context, payload: Payload) !void {
        try self.billing.send(payload.order_id);
    }
};

const Jobs = struct { invoices: *SendInvoice };

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var mongo_client: mongo.Client = try .init(init.gpa, io, .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    defer mongo_client.deinit();
    var diagnostics: mongo.Diagnostics = .{};
    mongo_client.connect(io, within(io, .fromSeconds(10)), &diagnostics) catch |err| {
        app.err("Cannot connect", .{ .reason = err, .details = diagnostics.message() });
        return err;
    };
    defer mongo_client.close(io);
    app.info("Connected", .{});
    try startAfresh(io, init.gpa, &mongo_client);

    // The store and the client, as in mongo_quick_start.zig.
    var store: mongo.SchedulerStore = try .init(init.gpa, io, &mongo_client, .{ .database = "shop" });
    defer store.deinit();
    try store.ensureIndexes(io, within(io, .fromSeconds(10)));
    const client: scheduler.Client = .init(init.gpa, io, store.store(), .{});

    // The three instances: a job and a worker each, all named "shop"; each
    // worker adds 32 random hex digits to the name, so that the logs and
    // the history tell them apart.
    var billing: Billing = .{};
    var invoices: [instances]SendInvoice = @splat(.{ .billing = &billing });
    var workers: [instances]scheduler.Worker(Jobs) = undefined;
    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.deinit(io);
    for (&workers, &invoices) |*w, *job| {
        w.* = try .init(init.gpa, io, store.store(), .{ .invoices = job }, .{ .instance = "shop" });
        made += 1;
    }
    for (&workers) |*w| try w.start(io);

    for (1..orders + 1) |order| {
        var key: [16]u8 = undefined;
        _ = try client.schedule(io, within(io, .fromSeconds(5)), SendInvoice, .{
            .key = try std.fmt.bufPrint(&key, "order-{d}", .{order}),
            .when = .{ .after = .fromSeconds(1) },
            .payload = .{ .order_id = @intCast(order), .amount_cents = 1000 + order },
        }, .{});
    }
    app.info("Scheduled", .{ .invoices = orders });

    // The invoices go out about a second from now: wait for all of them,
    // for 10 s at most, then stop the instances one after another.
    var waited: u32 = 0;
    while (billing.total.load(.acquire) < orders) : (waited += 1) {
        if (waited == 100) return error.InvoicesNotSent;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    for (&workers) |*w| try w.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }));

    // Every invoice once, and what the workers did together.
    var once: u32 = 0;
    for (billing.sent[1..]) |*n| {
        if (n.load(.acquire) == 1) once += 1;
    }
    app.info("Invoices sent", .{ .orders = orders, .once = once, .total = billing.total.load(.acquire) });
    var claimed: u64 = 0;
    var succeeded: u64 = 0;
    var taken_over: u64 = 0;
    for (&workers) |*w| {
        const stats = w.stats();
        claimed += stats.claimed;
        succeeded += stats.succeeded;
        taken_over += stats.taken_over;
    }
    app.info("Workers", .{ .claimed = claimed, .succeeded = succeeded, .taken_over = taken_over });

    // The history of all the instances in one place: a row for each run.
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const history = try client.history(io, within(io, .fromSeconds(5)), .{ .job = SendInvoice.scheduler_job.name }, .{}, arena_state.allocator(), .{});
    var good: u32 = 0;
    for (history.runs) |run| {
        if (run.outcome == .succeeded) good += 1;
    }
    app.info("History", .{ .rows = history.runs.len, .succeeded = good });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Drops the collections of the store, so that the history shows only
/// this run.
fn startAfresh(io: std.Io, gpa: std.mem.Allocator, mongo_client: *mongo.Client) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(mongo_client, "shop", &ids);
    const op: mongo.OperationContext = .of(within(io, .fromSeconds(10)));
    for ([_][]const u8{ "scheduler_jobs", "scheduler_runs" }) |name|
        try db.collection(name).drop(io, op, .{ .allocator = arena_state.allocator() });
}
```

```text
$ zig build run
2026-10-27T14:00:38.102Z INFO  [app] Connected
2026-10-27T14:00:38.114Z INFO  [scheduler] 1 job type, 10 workers, instance shop/9306778f0373721ca480074ae382dc81
2026-10-27T14:00:38.114Z INFO  [scheduler] 1 job type, 10 workers, instance shop/aa328e58f408f7965e6322229c49872f
2026-10-27T14:00:38.114Z INFO  [scheduler] 1 job type, 10 workers, instance shop/ca704d788b208ebfbca907d8fd1c768e
2026-10-27T14:00:38.145Z INFO  [app] Scheduled invoices=30
2026-10-27T14:00:39.253Z INFO  [scheduler] stopping
2026-10-27T14:00:39.253Z INFO  [scheduler] stopped
2026-10-27T14:00:39.254Z INFO  [scheduler] stopping
2026-10-27T14:00:39.254Z INFO  [scheduler] stopped
2026-10-27T14:00:39.254Z INFO  [scheduler] stopping
2026-10-27T14:00:39.254Z INFO  [scheduler] stopped
2026-10-27T14:00:39.254Z INFO  [app] Invoices sent orders=30 once=30 total=30
2026-10-27T14:00:39.254Z INFO  [app] Workers claimed=30 succeeded=30 taken_over=0
2026-10-27T14:00:39.256Z INFO  [app] History rows=30 succeeded=30
```

Each worker claims no more jobs than it has free slots, and a claim is
atomic: whichever worker asks first gets a job, and the others never see
it running. Thirty claims, thirty runs, thirty rows; which worker sent
which invoice changes from run to run, and the history says it, in the
`instance` of each row. How the claims, the leases and their renewals
keep one owner for each job, and what happens when an instance dies, is
in [Several instances](#several-instances).
