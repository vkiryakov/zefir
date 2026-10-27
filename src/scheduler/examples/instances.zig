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
