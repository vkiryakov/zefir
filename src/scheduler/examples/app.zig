//! The scheduler under zefir.App, without a server. The shop has two
//! schedulers: one for the jobs that all its instances share, such as the
//! invoices of orders, and one for the jobs that each instance runs for
//! itself, such as dropping the quotes it keeps in its memory. A module
//! declares the jobs as providers, which App builds with what they take,
//! and the stores, the clients and the workers as the beans of factories.
//! App starts the workers after their stores and stops them first,
//! together with the servers of a service. App gives every bean by its
//! type, so the client of each scheduler is a type of its own. In a
//! service the shared store is `mongo.SchedulerStore`; here a MemoryStore
//! stands in for it.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const scheduler = @import("scheduler");

/// App and the workers log through std.log; this sends their records to
/// the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// The client of the jobs that every instance of the shop shares.
pub const SharedClient = struct { client: scheduler.Client };
/// The client of the jobs that each instance runs for itself.
pub const LocalClient = struct { client: scheduler.Client };

/// The store of the shared jobs. In a service, the factory returns
/// mongo.SchedulerStore, on the client of MongoDB, a type of its own; here
/// a MemoryStore stands in for it, in a type of its own too, since the
/// local store is a MemoryStore as well.
pub const SharedStore = struct {
    memory: scheduler.MemoryStore,

    pub fn deinit(s: *SharedStore) void {
        s.memory.deinit();
    }
};

/// The quotes of prices that this instance keeps in its memory, by the
/// number of the customer; here only a count of them.
pub const Quotes = struct {
    held: std.atomic.Value(u32) = .init(0),
};

/// A shared job: the invoice of an order.
pub const SendInvoice = struct {
    logger: log.Logger,
    sent: std.atomic.Value(u32) = .init(0),

    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };
    pub const Payload = struct { order_id: u64 };

    /// App builds it by its `init`, whose params are what it takes.
    pub fn init(logger: *const log.Logger) SendInvoice {
        return .{ .logger = logger.scoped("invoices") };
    }

    pub fn run(self: *SendInvoice, _: *scheduler.Context, payload: Payload) !void {
        self.logger.info("Invoice sent", .{ .order = payload.order_id });
        _ = self.sent.fetchAdd(1, .release);
    }
};

/// A local job: drops a quote of this instance once it expires. Another
/// instance could not: the quote is in this one's memory.
pub const ExpireQuote = struct {
    quotes: *Quotes,
    logger: *const log.Logger,

    pub const scheduler_job: scheduler.Job = .{ .name = "expire-quote" };
    pub const Payload = struct { customer: u64 };

    pub fn run(self: *ExpireQuote, _: *scheduler.Context, payload: Payload) !void {
        self.logger.scoped("quotes").info("Quote dropped", .{ .customer = payload.customer });
        _ = self.quotes.held.fetchSub(1, .acq_rel);
    }
};

/// The jobs of each worker: App fills these structs of pointers by type.
pub const SharedJobs = struct { invoices: *SendInvoice };
pub const LocalJobs = struct { quotes: *ExpireQuote };

pub const ShopModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{ Quotes, SendInvoice, ExpireQuote },
        .factories = &.{Scheduling},
        // Ready objects from main: App hands them out, and never starts or
        // frees them.
        .values = &.{*const log.Logger},
    };

    /// Each pub fn is a bean: its params are what it takes, its return type
    /// the type of the bean.
    pub const Scheduling = struct {
        pub fn sharedStore(gpa: std.mem.Allocator, io: std.Io) SharedStore {
            return .{ .memory = .init(gpa, io, .{}) };
        }
        pub fn localStore(gpa: std.mem.Allocator, io: std.Io) scheduler.MemoryStore {
            return .init(gpa, io, .{});
        }
        /// The clients: the jobs take them to schedule other jobs, and so do
        /// the controllers of a service.
        pub fn sharedClient(gpa: std.mem.Allocator, io: std.Io, store: *SharedStore) SharedClient {
            return .{ .client = .init(gpa, io, store.memory.store(), .{}) };
        }
        pub fn localClient(gpa: std.mem.Allocator, io: std.Io, store: *scheduler.MemoryStore) LocalClient {
            return .{ .client = .init(gpa, io, store.store(), .{}) };
        }
        /// A worker has requestStop: App stops it with the servers, before
        /// the store it takes.
        pub fn sharedWorker(gpa: std.mem.Allocator, io: std.Io, store: *SharedStore, jobs: SharedJobs) !scheduler.Worker(SharedJobs) {
            return .init(gpa, io, store.memory.store(), jobs, .{ .instance = "shop" });
        }
        pub fn localWorker(gpa: std.mem.Allocator, io: std.Io, store: *scheduler.MemoryStore, jobs: LocalJobs) !scheduler.Worker(LocalJobs) {
            return .init(gpa, io, store.store(), jobs, .{ .instance = "shop-local" });
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Only the warnings of the workers: their start and stop are in the
    // quick start.
    const logger: log.Logger = try .init(init.gpa, io, .{ .format = .text, .scopes = &.{.{ .prefix = "scheduler", .level = .warn }} });
    defer logger.deinit();
    logger.installStdLog();
    const app_log = logger.scoped("app");

    var app = try core.App(ShopModule).init(init.gpa, io, .{&logger}, .{});
    defer app.deinit();
    try app.start();
    app_log.info("Started", .{});

    // What a handler of an order does: the invoice is a shared job, by
    // the key of the order.
    const shared: *SharedClient = app.get(SharedClient);
    _ = try shared.client.schedule(io, .root, SendInvoice, .{ .key = "order-42", .when = .{ .after = .zero }, .payload = .{ .order_id = 42 } }, .{});
    try waitFor(io, &app.get(SendInvoice).sent, 1);

    // A quote for customer 7, held by this instance: a local job drops it,
    // here at once, in a shop 15 minutes on.
    const quotes: *Quotes = app.get(Quotes);
    _ = quotes.held.fetchAdd(1, .acq_rel);
    const local: *LocalClient = app.get(LocalClient);
    _ = try local.client.schedule(io, .root, ExpireQuote, .{ .key = "customer-7", .when = .{ .after = .zero }, .payload = .{ .customer = 7 } }, .{});
    try waitFor(io, &quotes.held, 0);

    // What a signal does in a service: App stops the workers, then the
    // rest, and wait returns.
    app.requestStop();
    try app.wait();
    app_log.info("Stopped", .{ .state = app.state() });
}

/// Waits until `value` is `wanted`, 10 s at most.
fn waitFor(io: std.Io, value: *const std.atomic.Value(u32), wanted: u32) !void {
    for (0..500) |_| {
        if (value.load(.acquire) == wanted) return;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.JobDidNotRun;
}
