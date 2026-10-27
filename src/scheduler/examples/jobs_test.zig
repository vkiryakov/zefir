//! The tests of the jobs of Invoices.zig, as an application writes them:
//! a handler alone, with `scheduler.testing.call`; the jobs on a worker
//! and `scheduler.MemoryStore`; a store that fails, with
//! `scheduler.testing.FaultyStore`; and a rollout that parks a declared
//! job. `zig build test-scheduler` runs them.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("scheduler");
const Invoices = @import("Invoices.zig");

const io = testing.io;
const Worker = scheduler.Worker(struct { invoices: *Invoices.SendInvoice });

/// What the worker would give the first attempt of the claim `fence` of
/// the record of `life`: `testing.call` hands it to `run` as `ctx.info()`.
fn runInfo(job: []const u8, key: []const u8, run_key: []const u8, life: scheduler.Life, fence: u64) scheduler.RunInfo {
    const scheduled_at: scheduler.Instant = .fromUtc(2026, 10, 27, 9, 0, 0, .am);
    return .{
        .job = job,
        .key = key,
        .tenant = null,
        // "<job>/<key>/<scheduled_at in ms>"
        .run_key = run_key,
        .attempt = 1,
        .attempts = 5,
        .scheduled_at = scheduled_at,
        .started_at = scheduled_at,
        .missed = 0,
        .life = life,
        .fence = fence,
        .instance = "test/0123456789abcdef0123456789abcdef",
    };
}

/// A deadline for `shutdown`, 5 s on.
fn soon() std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
}

/// Waits until the billing service sent `n` invoices: a loop on the clock,
/// 10 s at most.
fn waitForInvoices(billing: *Invoices.Billing, n: usize) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake });
    while (billing.count(io) < n) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
}

test "an invoice goes out once for each run key" {
    var billing: Invoices.Billing = .init(testing.allocator);
    defer billing.deinit();
    var invoices: Invoices.SendInvoice = .{ .billing = &billing };
    const payload: Invoices.SendInvoice.Payload = .{ .order_id = 42, .amount_cents = 1999 };
    const first = runInfo("send-invoice", "order-42", "send-invoice/order-42/1793091600000", @splat(1), 1);
    try scheduler.testing.call(io, testing.allocator, &invoices, payload, first);
    // The same run again, as after a crash of the instance that ran it
    // before it wrote the outcome: the run key is the same, no invoice.
    var again = first;
    again.attempt = 2;
    again.fence = 2;
    try scheduler.testing.call(io, testing.allocator, &invoices, payload, again);
    try testing.expectEqual(1, billing.count(io));
    // The job of the key scheduled again, for another time, is another
    // run, with a run key of its own.
    const later = runInfo("send-invoice", "order-42", "send-invoice/order-42/1793178000000", @splat(2), 1);
    try scheduler.testing.call(io, testing.allocator, &invoices, payload, later);
    try testing.expectEqual(2, billing.count(io));
}

test "the invoice of an order that is gone fails with an error of give_up_on" {
    var billing: Invoices.Billing = .init(testing.allocator);
    defer billing.deinit();
    billing.gone = &.{42};
    var invoices: Invoices.SendInvoice = .{ .billing = &billing };
    const info = runInfo("send-invoice", "order-42", "send-invoice/order-42/1793091600000", @splat(1), 1);
    try testing.expectError(error.OrderGone, scheduler.testing.call(io, testing.allocator, &invoices, .{ .order_id = 42, .amount_cents = 1999 }, info));
    try testing.expectEqual(0, billing.count(io));
}

test "the ledger closes the night of a run once, whichever claim posts it" {
    var ledger: Invoices.Ledger = .init(testing.allocator);
    defer ledger.deinit();
    var close: Invoices.CloseDay = .{ .ledger = &ledger };
    const life: scheduler.Life = @splat(7);
    const night = "close-day//1793055600000";
    // Claim 1 closes the night, and its instance dies before it writes the
    // outcome. Claim 2 takes the job over and runs the same night again,
    // with the same run key and a greater fence: it closes nothing more.
    try scheduler.testing.call(io, testing.allocator, &close, {}, runInfo("close-day", "", night, life, 1));
    var again = runInfo("close-day", "", night, life, 2);
    again.attempt = 2;
    try scheduler.testing.call(io, testing.allocator, &close, {}, again);
    try testing.expectEqual(1, ledger.days_closed);
}

test "the ledger refuses the post of a claim that a newer one took over" {
    var ledger: Invoices.Ledger = .init(testing.allocator);
    defer ledger.deinit();
    var close: Invoices.CloseDay = .{ .ledger = &ledger };
    const life: scheduler.Life = @splat(7);
    // Claim 2 closes the night; claim 1, whose lease ran out and which went
    // on anyway, comes late and is refused.
    try scheduler.testing.call(io, testing.allocator, &close, {}, runInfo("close-day", "", "close-day//1793055600000", life, 2));
    try testing.expectError(error.StaleClaim, scheduler.testing.call(io, testing.allocator, &close, {}, runInfo("close-day", "", "close-day//1793055600000", life, 1)));
    // The record of the key made again is a new life, whose claims count
    // from 1 again: its first claim closes the next night.
    try scheduler.testing.call(io, testing.allocator, &close, {}, runInfo("close-day", "", "close-day//1793142000000", @splat(8), 1));
    // The run of the night after that, claimed two nights late, stands for
    // those two too: it closes three days.
    var late = runInfo("close-day", "", "close-day//1793228400000", @splat(8), 2);
    late.missed = 2;
    try scheduler.testing.call(io, testing.allocator, &close, {}, late);
    try testing.expectEqual(5, ledger.days_closed);
}

test "a worker sends the invoice when it is due, and the job goes" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    const client: scheduler.Client = .init(testing.allocator, io, memory.store(), .{});
    var billing: Invoices.Billing = .init(testing.allocator);
    defer billing.deinit();
    var invoices: Invoices.SendInvoice = .{ .billing = &billing };
    var worker: Worker = try .init(testing.allocator, io, memory.store(), .{ .invoices = &invoices }, .{ .poll_every = .fromMilliseconds(100) });
    defer worker.deinit(io);
    try worker.start(io);

    _ = try client.schedule(io, .root, Invoices.SendInvoice, .{ .key = "order-42", .when = .{ .after = .zero }, .payload = .{ .order_id = 42, .amount_cents = 1999 } }, .{});
    try waitForInvoices(&billing, 1);
    try worker.shutdown(io, soon());

    // A succeeded job leaves no record; its history keeps a row.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try client.get(io, .root, .of(Invoices.SendInvoice, "order-42"), arena.allocator(), .{}) == null);
    const history = try client.history(io, .root, .{ .job = "send-invoice", .key = "order-42" }, .{}, arena.allocator(), .{});
    try testing.expectEqual(1, history.runs.len);
    try testing.expectEqual(scheduler.RunOutcome.succeeded, history.runs[0].outcome);
    try testing.expectEqual(1, worker.stats().succeeded);
}

test "the worker waits while its store fails, and runs the job once it answers" {
    // The worker warns of the failures.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var faulty: scheduler.testing.FaultyStore = .init(memory.store());
    const client: scheduler.Client = .init(testing.allocator, io, faulty.store(), .{});
    var billing: Invoices.Billing = .init(testing.allocator);
    defer billing.deinit();
    var invoices: Invoices.SendInvoice = .{ .billing = &billing };
    var worker: Worker = try .init(testing.allocator, io, faulty.store(), .{ .invoices = &invoices }, .{ .poll_every = .fromMilliseconds(100) });
    defer worker.deinit(io);
    // The first three claims find the store unreachable.
    faulty.failNext(io, .claim, error.Unavailable, 3);
    try worker.start(io);

    _ = try client.schedule(io, .root, Invoices.SendInvoice, .{ .key = "order-42", .when = .{ .after = .zero }, .payload = .{ .order_id = 42, .amount_cents = 1999 } }, .{});
    try waitForInvoices(&billing, 1);
    const stats = worker.stats();
    try testing.expectEqual(3, stats.store_errors);
    try testing.expect(!stats.store_down);
    try worker.shutdown(io, soon());
}

test "after a lost reply, the same request again tells whether the job was made" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var faulty: scheduler.testing.FaultyStore = .init(memory.store());
    const client: scheduler.Client = .init(testing.allocator, io, faulty.store(), .{});
    const request: scheduler.Client.Request(Invoices.SendInvoice) = .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(60) },
        .payload = .{ .order_id = 42, .amount_cents = 1999 },
    };

    // The store cannot be reached: nothing was done, and the call is safe
    // to make again.
    faulty.failNext(io, .create, error.Unavailable, 1);
    try testing.expectError(error.Unavailable, client.schedule(io, .root, Invoices.SendInvoice, request, .{}));
    try testing.expectEqual(scheduler.Outcome.not_applied, scheduler.outcome(error.Unavailable));
    // The store makes the job, and its reply is lost: the outcome is
    // unknown.
    faulty.loseNextReply(io, .create);
    try testing.expectError(error.OutcomeUnknown, client.schedule(io, .root, Invoices.SendInvoice, request, .{}));
    try testing.expectEqual(scheduler.Outcome.unknown, scheduler.outcome(error.OutcomeUnknown));
    // The same request again: the key is taken, so the job was made.
    try testing.expectEqual(scheduler.Client.Scheduled.existing, try client.schedule(io, .root, Invoices.SendInvoice, request, .{}));
}

test "a declaration that left the code is parked until it is removed" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    const client: scheduler.Client = .init(testing.allocator, io, memory.store(), .{});
    var billing: Invoices.Billing = .init(testing.allocator);
    defer billing.deinit();
    var ledger: Invoices.Ledger = .init(testing.allocator);
    defer ledger.deinit();

    // Version 1 of the shop declares the close of the day: its start
    // writes the record of the declaration, whose key is "".
    var close: Invoices.CloseDay = .{ .ledger = &ledger };
    var v1: scheduler.Worker(struct { close: *Invoices.CloseDay }) = try .init(testing.allocator, io, memory.store(), .{ .close = &close }, .{});
    defer v1.deinit(io);
    try v1.start(io);
    try v1.shutdown(io, soon());

    // Version 2 closes the day of each tenant, with a job by key, and no
    // longer declares it. Its start finds the record of the declaration:
    // parked, which no instance of version 2 runs or removes. It warns,
    // and counts it.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    const CloseTenantDay = struct {
        pub const scheduler_job: scheduler.Job = .{ .name = "close-day" };

        pub fn run(_: *@This(), _: *scheduler.Context) !void {}
    };
    var close_tenant_day: CloseTenantDay = .{};
    var remind: Invoices.RemindUnpaid = .{ .billing = &billing };
    var v2: scheduler.Worker(struct { close: *CloseTenantDay, remind: *Invoices.RemindUnpaid }) = try .init(testing.allocator, io, memory.store(), .{ .close = &close_tenant_day, .remind = &remind }, .{});
    defer v2.deinit(io);
    try v2.start(io);
    try testing.expectEqual(1, v2.stats().undeclared);

    // Removed once, by hand, with the key "" that Ref.declared names.
    try testing.expect(try client.cancel(io, .root, .declared(CloseTenantDay), .{}));
    try v2.shutdown(io, soon());
}
