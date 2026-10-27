//! `scheduler.Context`, the context of one run of a job, and
//! `scheduler.RunInfo`, what is known about the run.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const Instant = @import("Instant.zig");
const Life = @import("record.zig").Life;

/// The context of one run. The worker makes one for each run; `run` gets a
/// borrowed pointer and must not keep it after it returns.
///
/// ```zig
/// pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
///     // The same key for every attempt of this run: an idempotency key.
///     try self.billing.send(ctx.operation(), ctx.io(), payload.order_id, ctx.info().run_key);
/// }
/// ```
pub const Context = opaque {
    /// The `std.Io` of the worker: every wait of the job goes through it.
    pub fn io(ctx: *Context) Io {
        return stateOf(ctx).io;
    }

    /// The deadline (when the job has a `timeout`), the token of this run
    /// and the trace, which goes on from the caller of `schedule`. The
    /// worker cancels the token, and the task of `run` with it, when the
    /// timeout passes, the worker stops, its lease is lost or cannot be
    /// confirmed, or `client.cancel` removed the job. A handler stops at
    /// its next point of cancellation; one that never reaches any holds
    /// its slot until it ends.
    pub fn operation(ctx: *Context) core.Context {
        return stateOf(ctx).operation;
    }

    /// The arena of the run, freed after the outcome is written. Parallel
    /// tasks of the handler must not use it.
    pub fn allocator(ctx: *Context) Allocator {
        return stateOf(ctx).arena;
    }

    /// What is known about the run.
    pub fn info(ctx: *Context) *const RunInfo {
        return &stateOf(ctx).info;
    }
};

/// What is known about one run.
pub const RunInfo = struct {
    job: []const u8,
    /// "" for a declared job.
    key: []const u8,
    tenant: ?[]const u8,
    /// "<job>/<key>/<scheduled_at in ms>": the same for every attempt of
    /// this run, so the key of idempotency for other systems.
    run_key: []const u8,
    /// The number of this attempt, from 1, and how many the policy allows.
    attempt: u32,
    attempts: u32,
    /// The time of the run by the plan (UTC), the same for every attempt.
    scheduled_at: Instant,
    /// When the store gave the job to this instance, by the store's clock.
    started_at: Instant,
    /// A repeating job: how many more runs of its schedule this one stands
    /// for (coalesce).
    missed: u32,
    /// The life of the record: 16 random bytes, new for a record created
    /// again with the same key.
    life: Life,
    /// The number of the claim in this life: one more with each claim.
    fence: u64,
    /// The instance: "shop/7f3a9c…".
    instance: []const u8,
};

/// What a `Context` reads: the worker and `testing.call` fill one for each
/// run. Internal to the module.
pub const State = struct {
    io: Io,
    operation: core.Context,
    arena: Allocator,
    info: RunInfo,
};

/// The context of `s`, which outlives it. Internal to the module.
pub fn of(s: *State) *Context {
    return @ptrCast(s);
}

fn stateOf(ctx: *Context) *State {
    return @ptrCast(@alignCast(ctx));
}
