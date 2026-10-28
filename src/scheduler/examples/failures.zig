//! Failures and retries: the shop charges the card of an order, and the
//! payment gateway fails in three ways. It is down for the first two
//! attempts of order 1, so the job tries again after a pause, and the
//! third attempt goes through. The card of order 2 has expired, an error of
//! `retry.give_up_on`, so the job ends failed at once; once the customer
//! gives a new card, the shop gives the job back its attempts with
//! `client.retry`. The gateway hangs on the first attempt of order 3, so
//! the run passes its timeout and is cancelled, and the next attempt goes
//! through. The jobs live in `scheduler.MemoryStore`, and the pauses are
//! short, so that the program ends in seconds.

const std = @import("std");
const log = @import("log");
const scheduler = @import("scheduler");

/// The worker logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// The job: charges the card of an order through the payment gateway,
/// which here fails as the story above tells.
const ChargeCard = struct {
    app: log.Logger,
    /// The customer of order 2 gave a new card.
    card_renewed: std.atomic.Value(bool) = .init(false),

    pub const scheduler_job: scheduler.Job = .{
        .name = "charge-card",
        // A charge takes less; a run past it is cancelled, and counts as a
        // failed attempt.
        .timeout = .fromMilliseconds(500),
        .retry = .{
            // Three attempts in all, 500 ms after the first failure and
            // 1 s after the second, each up to 20 % shorter.
            .attempts = 3,
            .delay = .fromMilliseconds(500),
            .multiplier = 2,
            // An expired card does not get better by trying again.
            .give_up_on = &.{error.CardExpired},
        },
        // A row of history for each attempt, kept for 30 days.
        .history = .{ .keep_for = .fromSeconds(30 * 24 * 60 * 60) },
    };

    pub const Payload = struct { order_id: u64, amount_cents: u64 };

    pub fn run(self: *ChargeCard, ctx: *scheduler.Context, payload: Payload) !void {
        const attempt = ctx.info().attempt;
        self.app.info("Charging", .{ .order = payload.order_id, .attempt = attempt });
        switch (payload.order_id) {
            1 => if (attempt < 3) return error.GatewayDown,
            2 => if (!self.card_renewed.load(.acquire)) return error.CardExpired,
            // A sleep is a point of cancellation: the timeout ends it.
            3 => if (attempt == 1) try ctx.io().sleep(.fromSeconds(10), .awake),
            else => {},
        }
        self.app.info("Charged", .{ .order = payload.order_id, .amount_cents = payload.amount_cents });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    var memory: scheduler.MemoryStore = .init(gpa, io, .{});
    defer memory.deinit();
    const client: scheduler.Client = .init(gpa, io, memory.store(), .{});
    var charges: ChargeCard = .{ .app = app };
    // One slot, so that one job runs at a time and the story keeps its
    // order; a poll every 100 ms, so that it ends sooner.
    var worker: scheduler.Worker(struct { charges: *ChargeCard }) = try .init(gpa, io, memory.store(), .{ .charges = &charges }, .{
        .instance = "shop",
        .workers = 1,
        .poll_every = .fromMilliseconds(100),
    });
    defer worker.deinit(io);
    try worker.start(io);

    // The orders one after another, each until its job ends.
    for ([_][]const u8{ "order-1", "order-2", "order-3" }, [_]u64{ 1, 2, 3 }) |key, id| {
        _ = try client.schedule(io, .root, ChargeCard, .{
            .key = key,
            .when = .{ .after = .zero },
            .payload = .{ .order_id = id, .amount_cents = 1000 * id },
        }, .{});
        try waitForEnd(io, gpa, client, key);
    }
    // The customer of order 2 gives a new card: the failed job waits
    // again, due at once, with all its attempts and the same run key.
    charges.card_renewed.store(true, .release);
    app.info("New card", .{ .order = 2 });
    const retried = try client.retry(io, .root, .of(ChargeCard, "order-2"), .{});
    try waitForEnd(io, gpa, client, "order-2");
    app.info("Retried", .{ .key = "order-2", .result = retried });
    try worker.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }));

    // The history: a row for each attempt, the newest first.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for ([_][]const u8{ "order-1", "order-2", "order-3" }) |key| {
        const history = try client.history(io, .root, .{ .job = "charge-card", .key = key }, .{}, arena_state.allocator(), .{});
        for (history.runs) |run| app.info("Run", .{ .key = key, .fence = run.fence, .attempt = run.attempt, .outcome = run.outcome, .error_name = run.error_name });
    }
    const stats = worker.stats();
    app.info("Worker", .{ .claimed = stats.claimed, .succeeded = stats.succeeded, .failed = stats.failed, .timed_out = stats.timed_out, .gave_up = stats.gave_up });
}

/// Waits until the job of `key` has ended: it succeeded, and its record
/// went, or it failed, and its record stays; 10 s at most.
fn waitForEnd(io: std.Io, gpa: std.mem.Allocator, client: scheduler.Client, key: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (0..500) |_| {
        _ = arena_state.reset(.retain_capacity);
        const record = try client.get(io, .root, .of(ChargeCard, key), arena_state.allocator(), .{}) orelse return;
        if (record.state == .failed) return;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.JobDidNotEnd;
}
