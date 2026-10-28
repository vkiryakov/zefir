//! Tests of the declarations of jobs: the checks of a job type, the refs
//! that name a job, and the context of a run. The compile errors of the
//! checks are fixtures in compile_errors/, listed in cases.zig.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const scheduler = @import("../root.zig");
const Job = @import("../Job.zig");
const context = @import("../Context.zig");

const io = testing.io;

/// A one-shot job with a payload, as an application declares it.
const SendInvoiceJob = struct {
    sent: u32 = 0,

    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        .timeout = .fromSeconds(30),
        .retry = .{ .give_up_on = &.{error.OrderGone} },
        .history = .{ .keep_for = .fromSeconds(90 * 24 * 60 * 60) },
    };

    pub const Payload = struct {
        order_id: u64,
        amount_cents: u64,
        note: ?[]const u8 = null,
    };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        if (payload.order_id == 0) return error.OrderGone;
        if (ctx.info().attempt == 0) return error.NoAttempt;
        self.sent += 1;
    }
};

/// A repeating job that the code declares, without a payload.
const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "nightly-cleanup",
        .repeat = .dailyAt(3, 30, 0, .am),
        .misfire = .{ .skip = .fromSeconds(15 * 60) },
    };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        try ctx.operation().check(std.Io.Clock.awake.now(ctx.io()));
    }
};

/// A repeating job with a payload whose every field has a default.
const Digest = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "digest.weekly_v2", .repeat = .weeklyOn(.monday, 9, 0, 0, .am) };
    pub const Payload = struct { limit: u32 = 10 };

    pub fn run(self: *Digest, ctx: *scheduler.Context, payload: Payload) error{TooMany}!void {
        _ = self;
        _ = ctx;
        if (payload.limit > 100) return error.TooMany;
    }
};

test "a job type with and without Payload passes its checks" {
    comptime {
        Job.assertJob(SendInvoiceJob);
        Job.assertJob(NightlyCleanup);
        Job.assertJob(Digest);
    }
    try testing.expect(Job.PayloadOf(SendInvoiceJob) == SendInvoiceJob.Payload);
    try testing.expect(Job.PayloadOf(NightlyCleanup) == void);
    try testing.expect(Job.RunResult(Digest) == error{TooMany}!void);
    try testing.expect(@typeInfo(Job.RunResult(SendInvoiceJob)).error_union.payload == void);
    try testing.expect(@typeInfo(Job.RunResult(NightlyCleanup)).error_union.payload == void);

    // The defaults of a declaration.
    const job: scheduler.Job = .{ .name = "send-invoice" };
    try testing.expectEqual(@as(?std.Io.Duration, null), job.timeout);
    try testing.expectEqual(@as(?u32, null), job.retry.attempts);
    try testing.expectEqual(std.Io.Duration.fromSeconds(1), job.retry.delay);
    try testing.expectEqual(@as(u32, 5), job.retry.multiplier);
    try testing.expectEqual(std.Io.Duration.fromSeconds(120), job.retry.max_delay);
    try testing.expectEqual(@as(usize, 0), job.retry.give_up_on.len);
    try testing.expect(job.repeat == null);
    try testing.expect(job.misfire == .coalesce);
    try testing.expect(job.history == .none);
    try testing.expect(job.when_done.succeeded == .none);
    try testing.expectEqual(scheduler.Retention{ .keep_for = .fromSeconds(30 * 24 * 60 * 60) }, job.when_done.failed);
}

test "Ref.of and Ref.declared name the job" {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    try testing.expectEqualStrings("send-invoice", ref.job);
    try testing.expectEqualStrings("order-42", ref.key);
    const declared: scheduler.Ref = .declared(NightlyCleanup);
    try testing.expectEqualStrings("nightly-cleanup", declared.job);
    try testing.expectEqualStrings("", declared.key);
    // A type without .repeat names its declared record too: the way to
    // remove the parked record of a declaration that left the code.
    const parked: scheduler.Ref = .declared(SendInvoiceJob);
    try testing.expectEqualStrings("send-invoice", parked.job);
    try testing.expectEqualStrings("", parked.key);
}

test "Context gives the io, the operation, the arena and the info of its state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var token: core.CancellationToken = .init;
    var state: context.State = .{
        .io = io,
        .operation = core.Context.root.withCancellation(&token),
        .arena = arena.allocator(),
        .info = .{
            .job = "send-invoice",
            .key = "order-42",
            .tenant = "acme",
            .run_key = "send-invoice/order-42/1793030400000",
            .attempt = 2,
            .attempts = 5,
            .scheduled_at = .fromUnixMs(1_793_030_400_000),
            .started_at = .fromUnixMs(1_793_030_401_250),
            .missed = 0,
            .life = @splat(7),
            .fence = 3,
            .instance = "shop/00112233445566778899aabbccddeeff",
        },
    };
    const ctx = context.of(&state);

    try testing.expect(ctx.io().vtable == io.vtable and ctx.io().userdata == io.userdata);
    try testing.expect(!ctx.operation().isCancelled());
    token.cancel();
    try testing.expect(ctx.operation().isCancelled());
    const bytes = try ctx.allocator().dupe(u8, "kept until the outcome is written");
    try testing.expectEqualStrings("kept until the outcome is written", bytes);
    const info = ctx.info();
    try testing.expectEqualStrings("send-invoice", info.job);
    try testing.expectEqualStrings("order-42", info.key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), info.tenant);
    try testing.expectEqualStrings("send-invoice/order-42/1793030400000", info.run_key);
    try testing.expectEqual(@as(u32, 2), info.attempt);
    try testing.expectEqual(@as(u32, 5), info.attempts);
    try testing.expectEqual(@as(i64, 1_793_030_400_000), info.scheduled_at.unix_ms);
    try testing.expectEqual(@as(i64, 1_793_030_401_250), info.started_at.unix_ms);
    try testing.expectEqual(@as(u32, 0), info.missed);
    try testing.expectEqualSlices(u8, &@as(scheduler.Life, @splat(7)), &info.life);
    try testing.expectEqual(@as(u64, 3), info.fence);
    try testing.expectEqualStrings("shop/00112233445566778899aabbccddeeff", info.instance);

    // A handler gets the context as it is.
    var invoices: SendInvoiceJob = .{};
    try invoices.run(ctx, .{ .order_id = 42, .amount_cents = 1999 });
    try testing.expectEqual(@as(u32, 1), invoices.sent);
    try testing.expectError(error.OrderGone, invoices.run(ctx, .{ .order_id = 0, .amount_cents = 1 }));
    var cleanup: NightlyCleanup = .{};
    try testing.expectError(error.Cancelled, cleanup.run(ctx));
}
