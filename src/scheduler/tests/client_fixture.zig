//! What the tests of scheduler.Client share: two job types, and a client
//! over a FaultyStore over a MemoryStore, which counts the calls that
//! reach the store.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const Store = scheduler.Store;

const io = testing.io;

/// A one-shot job with a payload.
pub const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };

    pub const Payload = struct {
        order_id: u64,
        amount_cents: u64,
        note: ?[]const u8 = null,
    };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

/// A job without a payload, which each tenant repeats.
pub const WeeklyReport = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "weekly-report" };

    pub fn run(self: *WeeklyReport, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

/// A client over a FaultyStore over a MemoryStore, and an arena for what
/// a test reads. Made in place: each part points at the one below.
pub const Fixture = struct {
    memory: scheduler.MemoryStore,
    faulty: scheduler.testing.FaultyStore,
    client: scheduler.Client,
    arena: std.heap.ArenaAllocator,

    pub fn init(f: *Fixture, limits: scheduler.Client.Options) void {
        f.memory = .init(testing.allocator, io, .{});
        f.faulty = .init(f.memory.store());
        f.client = .init(testing.allocator, io, f.faulty.store(), limits);
        f.arena = .init(testing.allocator);
    }

    pub fn deinit(f: *Fixture) void {
        f.memory.deinit();
        f.arena.deinit();
    }

    /// The store without the faults, for what a worker would do.
    pub fn store(f: *Fixture) Store {
        return f.memory.store();
    }

    pub fn options(f: *Fixture) Store.CallOptions {
        return .{ .allocator = f.arena.allocator() };
    }

    /// The record of `ref`, which must be there.
    pub fn record(f: *Fixture, ref: scheduler.Ref) !scheduler.Record {
        return (try f.store().get(io, .root, &ref, f.options())) orelse error.TestUnexpectedResult;
    }

    /// The due records of `job` that a claim of the worker "w1" takes, with
    /// a lease of a minute.
    pub fn claim(f: *Fixture, job: []const u8) ![]const Store.Claimed {
        const request: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{}, .keyed_only = &.{job}, .max = 100, .lease = .fromSeconds(60), .tag = @splat(1) };
        return (try f.store().claim(io, .root, &request, f.options())).claimed;
    }

    /// The finish of the claim of `r` by "w1", whose run failed.
    pub fn finish(f: *Fixture, r: scheduler.Record, next: Store.Next) !Store.FinishResult {
        const at = r.claimed_at orelse return error.TestUnexpectedResult;
        return f.store().finish(io, .root, &.{
            .ref = .{ .job = r.job, .key = r.key },
            .life = r.life,
            .owner = "w1",
            .fence = r.fence,
            .revision = r.revision,
            .tag = @splat(2),
            .next = next,
            .last = .{ .outcome = .failed, .error_name = "PaymentDeclined", .attempt = r.attempt, .started_at = at, .finished_at = at },
        }, f.options());
    }

    /// A one-shot record of SendInvoiceJob with `key`, due at once, claimed and
    /// failed for good: kept always.
    pub fn failed(f: *Fixture, key: []const u8) !scheduler.Record {
        _ = try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = key, .when = .{ .at = .fromUnixMs(0) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{});
        const claimed = try f.claim("send-invoice");
        if (claimed.len != 1) return error.TestUnexpectedResult;
        const done = try f.finish(claimed[0].record, .{ .done = .{ .state = .failed, .keep = .forever } });
        if (done != .done) return error.TestUnexpectedResult;
        return f.record(.of(SendInvoiceJob, key));
    }
};
