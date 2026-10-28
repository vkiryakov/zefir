//! `scheduler.testing.FaultyStore`: any store behind a wrapper that fails
//! on demand, for the tests of a worker or of an application: the store's
//! errors, calls that hang until their deadline, and replies lost after the
//! store applied the change, without MongoDB.
//!
//! ```zig
//! var memory: scheduler.MemoryStore = .init(gpa, io, .{});
//! defer memory.deinit();
//! var faulty: scheduler.testing.FaultyStore = .init(memory.store());
//! // The next three claims find the store unreachable.
//! faulty.failNext(io, .claim, error.Unavailable, 3);
//! const store = faulty.store(); // for the client and the worker
//! ```
//!
//! Each operation keeps its faults in a queue, in the order they were asked
//! for, and each call takes one fault of its operation: `failNext` with
//! `times` is one fault for `times` calls. A call without a fault reaches
//! the inner store as it is, and `now` always does. A queue holds at most 8
//! faults; a ninth panics. One `Io.Mutex` guards the queues and the counts,
//! never during a call of the inner store.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const core = @import("core");
const Diagnostics = @import("../Diagnostics.zig");
const Instant = @import("../Instant.zig");
const Store = @import("../Store.zig");
const record = @import("../record.zig");
const StoreError = Store.StoreError;

const FaultyStore = @This();

inner: Store,
mutex: Io.Mutex = .init,
queues: std.EnumArray(Op, Queue) = .initFill(.{}),
reached: std.EnumArray(Op, u32) = .initFill(0),

/// The operations of a store that fail on demand (`now` never fails).
pub const Op = enum { create, get, update, remove, list, claim, renew, finish, history };

pub const name = "faulty";

const capacity = 8;

/// The longest single sleep of a stall: some `std.Io` implementations
/// overflow on a very long one.
const max_step: i96 = std.time.ns_per_hour;

const Fault = union(enum) {
    /// The next `times` calls fail with `err`.
    fail: struct { err: StoreError, times: u32 },
    /// The next call waits this long first.
    stall: Duration,
    /// The next call reaches the store, and its reply is lost.
    lose,
};

/// The faults of one operation, the next one first.
const Queue = struct {
    faults: [capacity]Fault = undefined,
    len: usize = 0,

    fn push(q: *Queue, fault: Fault) void {
        if (q.len == capacity) @panic("zefir-scheduler: testing.FaultyStore keeps at most 8 faults of an operation: let calls take some first");
        q.faults[q.len] = fault;
        q.len += 1;
    }

    /// The fault of the next call, or null.
    fn take(q: *Queue) ?Fault {
        if (q.len == 0) return null;
        switch (q.faults[0]) {
            .fail => |*fail| if (fail.times > 1) {
                fail.times -= 1;
                return .{ .fail = .{ .err = fail.err, .times = 1 } };
            },
            .stall, .lose => {},
        }
        const fault = q.faults[0];
        std.mem.copyForwards(Fault, q.faults[0 .. q.len - 1], q.faults[1..q.len]);
        q.len -= 1;
        return fault;
    }
};

/// Wraps `inner`, without faults.
pub fn init(inner: Store) FaultyStore {
    return .{ .inner = inner };
}

/// The store with the faults, behind the contract. Do not move it after
/// the first call.
pub fn store(f: *FaultyStore) Store {
    return .init(f);
}

/// The next `times` calls of `op` fail with `err` and reach no store.
pub fn failNext(f: *FaultyStore, io: Io, op: Op, err: StoreError, times: u32) void {
    if (times == 0) return;
    f.push(io, op, .{ .fail = .{ .err = err, .times = times } });
}

/// The next call of `op` waits `duration` first. Its deadline coming first
/// ends it with OutcomeUnknown, the inner store untouched; a cancel of its
/// task too, and the task stays cancelled.
pub fn stallNext(f: *FaultyStore, io: Io, op: Op, duration: Duration) void {
    f.push(io, op, .{ .stall = duration });
}

/// The next call of `op` reaches the inner store, which applies it; the
/// caller gets OutcomeUnknown. The reply is dropped whole: the inner store
/// answers into memory of the FaultyStore's own, not `options.allocator`.
pub fn loseNextReply(f: *FaultyStore, io: Io, op: Op) void {
    f.push(io, op, .lose);
}

/// Calls of `op` that reached the inner store.
pub fn calls(f: *FaultyStore, io: Io, op: Op) u32 {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    return f.reached.get(op);
}

fn push(f: *FaultyStore, io: Io, op: Op, fault: Fault) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    f.queues.getPtr(op).push(fault);
}

/// The fault of the next call of `op`, or null. A call without a fault and
/// one whose reply is lost reach the store, and count so at once.
fn next(f: *FaultyStore, io: Io, op: Op) ?Fault {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    const fault = f.queues.getPtr(op).take();
    const reaches = if (fault) |x| x == .lose else true;
    if (reaches) f.reached.getPtr(op).* += 1;
    return fault;
}

fn reach(f: *FaultyStore, io: Io, op: Op) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    f.reached.getPtr(op).* += 1;
}

/// What the wrapper of `op` in `Store` returns.
fn Result(comptime op: Op) type {
    return @typeInfo(@TypeOf(@field(Store, @tagName(op)))).@"fn".return_type.?;
}

/// A call of `op` and its fault: the error, a stall first, or the reply
/// lost; without one, the answer of the inner store.
fn call(f: *FaultyStore, io: Io, ctx: core.Context, comptime op: Op, request: anytype, options: Store.CallOptions) Result(op) {
    const method = @field(Store, @tagName(op));
    if (f.next(io, op)) |fault| switch (fault) {
        .fail => |fail| return failed(options.diagnostics, fail.err, "testing.FaultyStore: {t} failed on demand with error.{t}", .{ op, fail.err }),
        .stall => |duration| {
            try stall(io, ctx, op, duration, options.diagnostics);
            f.reach(io, op);
        },
        .lose => {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            if (method(f.inner, io, ctx, request, .{ .allocator = arena.allocator() })) |_| {} else |_| {}
            return failed(options.diagnostics, error.OutcomeUnknown, "testing.FaultyStore: the reply of {t} was lost on demand", .{op});
        },
    };
    return method(f.inner, io, ctx, request, options);
}

/// Waits `duration` on the awake clock, unless the deadline of `ctx` comes
/// first or the task is cancelled: then error.OutcomeUnknown, and a
/// cancelled task stays cancelled.
fn stall(io: Io, ctx: core.Context, op: Op, duration: Duration, d: ?*Diagnostics) error{OutcomeUnknown}!void {
    const end = Io.Clock.awake.now(io).nanoseconds +| @max(duration.nanoseconds, 0);
    const deadline: ?i96 = if (ctx.deadline) |x| x.expires.nanoseconds else null;
    while (true) {
        const at = Io.Clock.awake.now(io).nanoseconds;
        if (deadline) |x| if (x <= end and at >= x)
            return failed(d, error.OutcomeUnknown, "testing.FaultyStore: {t} stalled until its deadline", .{op});
        if (at >= end) return;
        const until = if (deadline) |x| @min(x, end) else end;
        io.sleep(.{ .nanoseconds = @min(until - at, max_step) }, .awake) catch {
            io.recancel();
            return failed(d, error.OutcomeUnknown, "testing.FaultyStore: {t} stalled, and its task was cancelled", .{op});
        };
    }
}

fn failed(d: ?*Diagnostics, err: anytype, comptime format: []const u8, args: anytype) @TypeOf(err) {
    if (d) |x| x.set(null, format, args);
    return err;
}

pub fn now(f: *FaultyStore, io: Io) Instant {
    return f.inner.now(io);
}

pub fn create(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) StoreError!Store.CreateResult {
    return f.call(io, ctx, .create, request, options);
}

pub fn get(f: *FaultyStore, io: Io, ctx: core.Context, ref: *const record.Ref, options: Store.CallOptions) StoreError!?record.Record {
    return f.call(io, ctx, .get, ref, options);
}

pub fn update(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) StoreError!Store.UpdateResult {
    return f.call(io, ctx, .update, request, options);
}

pub fn remove(f: *FaultyStore, io: Io, ctx: core.Context, ref: *const record.Ref, options: Store.CallOptions) StoreError!bool {
    return f.call(io, ctx, .remove, ref, options);
}

pub fn list(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.ListRequest, options: Store.CallOptions) StoreError!record.RecordPage {
    return f.call(io, ctx, .list, request, options);
}

pub fn claim(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) StoreError!Store.ClaimResult {
    return f.call(io, ctx, .claim, request, options);
}

pub fn renew(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.RenewRequest, options: Store.CallOptions) StoreError!Store.RenewResult {
    return f.call(io, ctx, .renew, request, options);
}

pub fn finish(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) StoreError!Store.FinishResult {
    return f.call(io, ctx, .finish, request, options);
}

pub fn history(f: *FaultyStore, io: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) StoreError!record.RunPage {
    return f.call(io, ctx, .history, request, options);
}
