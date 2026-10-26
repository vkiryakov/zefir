//! `scheduler.MemoryStore`: a store in the memory of the process. There is
//! no database, so nothing survives a restart and each instance runs only
//! its own jobs; a declared job runs in every instance. For one instance,
//! for tests, and for jobs that each instance must run on its own.
//!
//! ```zig
//! var memory: scheduler.MemoryStore = .init(gpa, io, .{});
//! defer memory.deinit();
//! const client: scheduler.Client = .init(gpa, io, memory.store(), .{});
//! ```
//!
//! Its clock is the process's `Clock.real`, and `now` is that clock. One
//! `Io.Mutex` guards the records for short sections without I/O; a claim
//! walks an index of when records may be claimed, by job, and costs
//! O(k log n) for k records claimed. Expired records and rows go at the
//! next call; when there are more finished records or rows than `Options`
//! allows, the oldest go, with one warning. Durability, rule 8 of the
//! contract, is the exception: nothing outlives the process. No outcome is
//! ever unknown, so the store keeps no tags. Every call comes on the `io`
//! of `init`: another one panics in safe builds. `gpa` must be thread-safe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = @import("Diagnostics.zig");
const Instant = @import("Instant.zig");
const Store = @import("Store.zig");
const Table = @import("memory/Table.zig");
const record = @import("record.zig");
const StoreError = Store.StoreError;

const log = std.log.scoped(.scheduler);

const MemoryStore = @This();

io: Io,
mutex: Io.Mutex = .init,
table: Table,

pub const Options = struct {
    /// At most this many rows of the history; the oldest go.
    max_history: u32 = 1000,
    /// At most this many finished records, kept for their history; the
    /// oldest go.
    max_finished: u32 = 1000,
};

pub const name = "memory";

/// Without I/O. `gpa` must be thread-safe: the store allocates from the
/// tasks that call it.
pub fn init(gpa: Allocator, io: Io, options: Options) MemoryStore {
    return .{ .io = io, .table = .init(gpa, options.max_history, options.max_finished) };
}

/// The store behind the contract. Do not move the store after the first
/// call.
pub fn store(s: *MemoryStore) Store {
    return .init(s);
}

/// Frees every record and row; no call may be in flight.
pub fn deinit(s: *MemoryStore) void {
    s.table.deinit();
    s.* = undefined;
}

pub fn now(s: *MemoryStore, io: Io) Instant {
    s.checkIo(io);
    return clock(io);
}

pub fn create(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) StoreError!Store.CreateResult {
    const at = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.create(at, request, options.diagnostics);
}

pub fn get(s: *MemoryStore, io: Io, ctx: core.Context, ref: *const record.Ref, options: Store.CallOptions) StoreError!?record.Record {
    _ = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.get(ref.*, options.allocator);
}

pub fn update(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) StoreError!Store.UpdateResult {
    const at = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.update(at, request, options.allocator, options.diagnostics);
}

pub fn remove(s: *MemoryStore, io: Io, ctx: core.Context, ref: *const record.Ref, options: Store.CallOptions) StoreError!bool {
    _ = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.remove(ref.*);
}

pub fn list(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.ListRequest, options: Store.CallOptions) StoreError!record.RecordPage {
    _ = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.list(request, options.allocator, options.diagnostics);
}

pub fn claim(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) StoreError!Store.ClaimResult {
    const at = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.claim(at, request, options.allocator, options.diagnostics);
}

pub fn renew(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.RenewRequest, options: Store.CallOptions) StoreError!Store.RenewResult {
    const at = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.renew(at, request);
}

pub fn finish(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) StoreError!Store.FinishResult {
    const at = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.finish(at, request, options.allocator, options.diagnostics);
}

pub fn history(s: *MemoryStore, io: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) StoreError!record.RunPage {
    _ = try s.enter(io, ctx, options.diagnostics);
    defer s.leave(io);
    return s.table.history(request, options.allocator, options.diagnostics);
}

fn clock(io: Io) Instant {
    return .fromTimestamp(Io.Clock.real.now(io));
}

/// In safe builds, a call on another `std.Io` than the one of `init`
/// panics: the vtable and the instance both count.
fn checkIo(s: *const MemoryStore, io: Io) void {
    if (!std.debug.runtime_safety) return;
    if (io.vtable != s.io.vtable or io.userdata != s.io.userdata)
        @panic("zefir-scheduler: a call on another std.Io than the store's: pass the io of MemoryStore.init");
}

/// Rules 3 and 4 of the contract before any change, then the lock, and the
/// records that expired by now go. Returns the store's now.
fn enter(s: *MemoryStore, io: Io, ctx: core.Context, d: ?*Diagnostics) StoreError!Instant {
    s.checkIo(io);
    if (ctx.remaining(Io.Clock.awake.now(io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) return fail(d, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the call");
    }
    if (ctx.isCancelled()) return fail(d, error.Cancelled, "the token was cancelled before the call");
    s.mutex.lockUncancelable(io);
    const at = clock(io);
    s.table.purge(at);
    return at;
}

/// Lets go of the lock, then warns once about each kind that the limits
/// evicted.
fn leave(s: *MemoryStore, io: Io) void {
    const evicted = s.table.takeEvictions();
    const limits = .{ s.table.max_finished, s.table.max_history };
    s.mutex.unlock(io);
    if (evicted.records) log.warn("MemoryStore keeps at most {d} finished records (max_finished): the oldest go", .{limits[0]});
    if (evicted.rows) log.warn("MemoryStore keeps at most {d} rows of history (max_history): the oldest go", .{limits[1]});
}

fn fail(d: ?*Diagnostics, err: StoreError, comptime text: []const u8) StoreError {
    if (d) |x| x.set(null, text, .{});
    return err;
}
