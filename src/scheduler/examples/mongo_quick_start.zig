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
const SendInvoiceJob = struct {
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

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
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
    var invoices: SendInvoiceJob = .{ .app = app };
    var worker: scheduler.Worker(struct { invoices: *SendInvoiceJob }) = try .init(init.gpa, io, store.store(), .{ .invoices = &invoices }, .{ .instance = "shop" });
    defer worker.deinit(io);
    try worker.start(io);

    const scheduled = try client.schedule(io, within(io, .fromSeconds(5)), SendInvoiceJob, .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(1) },
        .payload = .{ .order_id = 42, .amount_cents = 1999 },
    }, .{});
    app.info("Scheduled", .{ .job = SendInvoiceJob.scheduler_job.name, .key = "order-42", .result = scheduled });

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
    const record = try client.get(io, ctx, .of(SendInvoiceJob, "order-42"), arena, .{});
    app.info("Record", .{ .found = record != null });
    const history = try client.history(io, ctx, .{ .job = SendInvoiceJob.scheduler_job.name, .key = "order-42" }, .{}, arena, .{});
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
