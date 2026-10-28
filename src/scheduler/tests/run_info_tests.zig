//! Tests of what a run knows of itself: its RunInfo, the context of its
//! operation, and scheduler.testing.call, which runs a handler without a
//! store or a worker.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const scheduler = @import("../root.zig");
const run_info = @import("../worker/run_info.zig");
const Instant = scheduler.Instant;
const Record = scheduler.Record;
const RunInfo = scheduler.RunInfo;

const io = testing.io;
const owner = "shop/00112233445566778899aabbccddeeff";
/// 2026-10-24T03:30:00Z: 1792812600000 ms from the epoch.
const scheduled: Instant = .fromUtc(2026, 10, 24, 3, 30, 0, .h24);
const claimed: Instant = .fromUtc(2026, 10, 24, 3, 30, 2, .h24);

/// A record as a claim returns it, at its first attempt.
fn claim(job: []const u8, key: []const u8) Record {
    return .{
        .job = job,
        .key = key,
        .tenant = "acme",
        .state = .running,
        .plan = "",
        .payload = "{}",
        .scheduled_at = scheduled,
        .run_at = null,
        .attempt = 1,
        .fence = 1,
        .revision = 0,
        .pause_requested = false,
        .owner = owner,
        .claimed_at = claimed,
        .lease_until = claimed.add(.fromSeconds(60)),
        .last = null,
        .created_at = scheduled,
        .updated_at = scheduled,
        .finished_at = null,
        .expires_at = null,
        .trace = null,
        .life = @splat(7),
        .unreadable_since = null,
    };
}

test "run_key is job/key/scheduled_at in ms, the same for every attempt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = claim("send-invoice", "order-42");
    const first = try run_info.runInfo(a, &r, 5, 0, owner);
    try testing.expectEqualStrings("send-invoice/order-42/1792812600000", first.run_key);
    try testing.expectEqualStrings("send-invoice", first.job);
    try testing.expectEqualStrings("order-42", first.key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), first.tenant);
    try testing.expectEqual(@as(u32, 1), first.attempt);
    try testing.expectEqual(@as(u32, 5), first.attempts);
    try testing.expectEqual(scheduled, first.scheduled_at);
    try testing.expectEqual(claimed, first.started_at);
    try testing.expectEqual(@as(u32, 0), first.missed);
    try testing.expectEqualSlices(u8, &r.life, &first.life);
    try testing.expectEqual(@as(u64, 1), first.fence);
    try testing.expectEqualStrings(owner, first.instance);

    // The third attempt, claimed later by another instance: the same run,
    // the same key.
    r.attempt = 3;
    r.fence = 3;
    r.claimed_at = claimed.add(.fromSeconds(30));
    const third = try run_info.runInfo(a, &r, 5, 0, "shop/ffeeddccbbaa99887766554433221100");
    try testing.expectEqualStrings(first.run_key, third.run_key);
    try testing.expectEqual(@as(u32, 3), third.attempt);
    try testing.expectEqual(@as(u64, 3), third.fence);
    try testing.expectEqual(claimed.add(.fromSeconds(30)), third.started_at);
    try testing.expectEqualStrings("shop/ffeeddccbbaa99887766554433221100", third.instance);

    // The record of a declaration has the key "", and a run that stands
    // for missed moments says how many.
    var nightly = claim("nightly-cleanup", "");
    nightly.tenant = null;
    nightly.plan = "daily 03:30:00";
    const info = try run_info.runInfo(a, &nightly, 1, 3, owner);
    try testing.expectEqualStrings("nightly-cleanup//1792812600000", info.run_key);
    try testing.expect(info.tenant == null);
    try testing.expectEqual(@as(u32, 3), info.missed);
    try testing.expectEqual(@as(u32, 1), info.attempts);

    // The strings are the arena's: the info outlives the record it came
    // from.
    var key_buffer = "order-77".*;
    var copy = claim("send-invoice", &key_buffer);
    const own = try run_info.runInfo(a, &copy, 5, 0, owner);
    key_buffer = "XXXXXXXX".*;
    try testing.expectEqualStrings("order-77", own.key);
}

test "operation continues the record's trace with a new span" {
    var token: core.CancellationToken = .init;
    const traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const ctx = run_info.operation(io, traceparent, null, &token);
    const trace = ctx.trace orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &trace.trace_id.toHex());
    try testing.expect(trace.span_id.isValid());
    try testing.expect(!std.mem.eql(u8, "00f067aa0ba902b7", &trace.span_id.toHex()));
    try testing.expect(trace.flags.sampled);
    try testing.expect(!trace.is_remote);
    // Each run of the record is a span of its own.
    const again = (run_info.operation(io, traceparent, null, &token)).trace orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &trace.trace_id.bytes, &again.trace_id.bytes);
    try testing.expect(!std.mem.eql(u8, &trace.span_id.bytes, &again.span_id.bytes));
    // The calls of the job carry it on as their parent.
    var buffer: [core.w3c.traceparent_len]u8 = undefined;
    const sent = core.w3c.formatTraceparent(trace, &buffer);
    try testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-", sent[0..36]);
    try testing.expectEqualStrings(&trace.span_id.toHex(), sent[36..52]);
}

test "without a trace a run gets one of its own" {
    var token: core.CancellationToken = .init;
    const trace = (run_info.operation(io, null, null, &token)).trace orelse return error.TestUnexpectedResult;
    try testing.expect(trace.isValid());
    try testing.expect(!trace.is_remote);
    const other = (run_info.operation(io, null, null, &token)).trace orelse return error.TestUnexpectedResult;
    try testing.expect(!std.mem.eql(u8, &trace.trace_id.bytes, &other.trace_id.bytes));
    // A traceparent that does not read starts a trace of its own too.
    const unread = (run_info.operation(io, "00-not-a-traceparent", null, &token)).trace orelse return error.TestUnexpectedResult;
    try testing.expect(unread.isValid());
}

test "operation has the deadline of timeout and the token" {
    var token: core.CancellationToken = .init;
    const before = Io.Clock.awake.now(io);
    const ctx = run_info.operation(io, null, .fromSeconds(30), &token);
    const after = Io.Clock.awake.now(io);
    const deadline = ctx.deadline orelse return error.TestUnexpectedResult;
    const thirty: i96 = 30 * std.time.ns_per_s;
    try testing.expect(deadline.expires.nanoseconds >= before.nanoseconds + thirty);
    try testing.expect(deadline.expires.nanoseconds <= after.nanoseconds + thirty);
    try testing.expectEqual(@as(?*const core.CancellationToken, &token), ctx.cancellation);
    try ctx.check(Io.Clock.awake.now(io));
    token.cancel();
    try testing.expectError(error.Cancelled, ctx.check(Io.Clock.awake.now(io)));
    // Without a timeout, no deadline.
    const open = run_info.operation(io, null, null, &token);
    try testing.expect(open.deadline == null);
    try testing.expect(open.isCancelled());
}

/// A job that tells what its context gave it.
const SendInvoiceJob = struct {
    buffer: [128]u8 = undefined,
    said: []const u8 = "",
    deadline: bool = true,
    traced: bool = false,

    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice", .retry = .{ .give_up_on = &.{error.OrderGone} } };
    pub const Payload = struct { order_id: u64 };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        if (payload.order_id == 0) return error.OrderGone;
        const info = ctx.info();
        // The memory of the run, freed after it: a copy stays in the job.
        const text = try std.fmt.allocPrint(ctx.allocator(), "order {d}, attempt {d} of {d}, {s}", .{ payload.order_id, info.attempt, info.attempts, info.run_key });
        self.said = try std.fmt.bufPrint(&self.buffer, "{s}", .{text});
        const operation = ctx.operation();
        self.deadline = operation.deadline != null;
        self.traced = operation.trace != null;
        try operation.check(Io.Clock.awake.now(ctx.io()));
    }
};

/// A job without a payload.
const NightlyCleanup = struct {
    runs: u32 = 0,

    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(3, 30, 0, .am) };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        if (ctx.info().key.len != 0) return error.NotDeclared;
        self.runs += 1;
    }
};

test "testing.call runs a job with an arena and the given info" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = claim("send-invoice", "order-42");
    r.attempt = 2;
    const info = try run_info.runInfo(arena.allocator(), &r, 5, 0, owner);

    var invoices: SendInvoiceJob = .{};
    try scheduler.testing.call(io, testing.allocator, &invoices, .{ .order_id = 42 }, info);
    try testing.expectEqualStrings("order 42, attempt 2 of 5, send-invoice/order-42/1792812600000", invoices.said);
    try testing.expect(!invoices.deadline);
    try testing.expect(invoices.traced);
    // What `run` returns, call returns.
    try testing.expectError(error.OrderGone, scheduler.testing.call(io, testing.allocator, &invoices, .{ .order_id = 0 }, info));

    // A job without Payload takes {} for it.
    var cleanup: NightlyCleanup = .{};
    var declared = info;
    declared.job = "nightly-cleanup";
    declared.key = "";
    try scheduler.testing.call(io, testing.allocator, &cleanup, {}, declared);
    try testing.expectEqual(@as(u32, 1), cleanup.runs);
    try testing.expectError(error.NotDeclared, scheduler.testing.call(io, testing.allocator, &cleanup, {}, info));
}
