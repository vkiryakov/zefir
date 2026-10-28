//! The quick start of the guide: a shop sends the invoice of an order a
//! second after the order. The jobs live in `scheduler.MemoryStore`, so
//! the program needs no server: it starts a worker, puts the invoice of
//! order 42 on its time, waits for the run, and stops the worker.

const std = @import("std");
const log = @import("log");
const scheduler = @import("scheduler");

/// The worker logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// The job: the invoice of an order. Its fields are what it needs, the
/// data of one run is its Payload, and `run` does the work.
const SendInvoice = struct {
    app: log.Logger,
    sent: std.atomic.Value(u32) = .init(0),

    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };

    pub const Payload = struct { order_id: u64, amount_cents: u64 };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
        self.app.info("Invoice sent", .{ .order = payload.order_id, .amount_cents = payload.amount_cents, .attempt = ctx.info().attempt });
        _ = self.sent.fetchAdd(1, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // The store keeps the jobs: the client puts them on their time, the
    // worker runs them.
    var memory: scheduler.MemoryStore = .init(gpa, io, .{});
    defer memory.deinit();
    const client: scheduler.Client = .init(gpa, io, memory.store(), .{});
    var invoices: SendInvoice = .{ .app = app };
    var worker: scheduler.Worker(struct { invoices: *SendInvoice }) = try .init(gpa, io, memory.store(), .{ .invoices = &invoices }, .{ .instance = "shop" });
    defer worker.deinit(io);
    try worker.start(io);

    // The invoice of order 42, a second from now. The key names the job,
    // so the same request again changes nothing.
    const request: scheduler.Client.Request(SendInvoice) = .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(1) },
        .payload = .{ .order_id = 42, .amount_cents = 1999 },
    };
    app.info("Scheduled", .{ .result = try client.schedule(io, .root, SendInvoice, request, .{}) });
    app.info("Scheduled again", .{ .result = try client.schedule(io, .root, SendInvoice, request, .{}) });

    // Wait for the run, then stop: the worker takes no more jobs and
    // waits for the runs to end, here for 5 s at most.
    while (invoices.sent.load(.acquire) == 0) try io.sleep(.fromMilliseconds(50), .awake);
    try worker.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }));
}
