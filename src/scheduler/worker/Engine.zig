//! What `scheduler.Worker(Jobs)` does, without its type parameter: the
//! settings, the state and the counters, and from the start on the poll
//! task, the slot tasks and the stop. `Worker(Jobs)` hands it its jobs as
//! entries, each with its policy and its run behind function pointers.
//! Internal to the module.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("../Diagnostics.zig");
const Instant = @import("../Instant.zig");
const Store = @import("../Store.zig");
const record = @import("../record.zig");
const Context = @import("../Context.zig").Context;
const Policy = @import("policy.zig").Policy;
const Stats = @import("stats.zig").Stats;
const Counters = @import("stats.zig").Counters;
const declared = @import("declared.zig");
const poll = @import("poll.zig");
const Slot = @import("Slot.zig");
const core = @import("core");

const Engine = @This();
const log = std.log.scoped(.scheduler);

pub const Options = struct {
    /// How many jobs this instance runs at once.
    workers: u16 = 10,
    /// How long a claim lives without a renewal, by the store's clock.
    lease: Duration = .fromSeconds(60),
    /// How often a running job renews its lease; `init` wants `lease` more
    /// than twice this.
    renew_every: Duration = .fromSeconds(20),
    /// How often to ask the store when it did not say when the next job
    /// is due.
    poll_every: Duration = .fromSeconds(1),
    /// The deadline of each call of the store.
    store_timeout: Duration = .fromSeconds(5),
    /// How long the running jobs go on after a stop is asked for.
    shutdown_grace: Duration = .fromSeconds(10),
    /// How long `start` waits for the records of the declared jobs.
    start_timeout: Duration = .fromSeconds(10),
    /// The longest pause of the poll while the store fails.
    max_backoff: Duration = .fromSeconds(30),
    /// How long in a row a job may stay unreadable for every instance that
    /// claims it before it ends `failed`. Longer than the longest rollout.
    unreadable_limit: Duration = .fromSeconds(60 * 60),
    /// The name of this instance in logs and records, 1–64 bytes of UTF-8
    /// without NUL; the worker adds 16 random bytes in hex: "shop/7f3a…".
    instance: []const u8 = "worker",
    /// Why `init` refused the settings.
    diagnostics: ?*Diagnostics = null,
};

/// Where a worker is: built, starting, running, stopping (no new claims,
/// the runs end), stopped.
pub const State = enum(u8) { configured, starting, running, draining, stopped };
pub const InitError = error{ InvalidArgument, OutOfMemory };
pub const StartError = Store.StoreError || error{ InvalidState, ConcurrencyUnavailable, Contended };
pub const WaitError = error{ InvalidState, Canceled };
pub const ShutdownError = error{ ShutdownTimeout, Canceled };

/// A job of the worker behind function pointers.
pub const Entry = struct {
    policy: Policy,
    /// The name of the job's type, for the hints of the logs.
    type_name: []const u8,
    job: *anyopaque,
    /// The payload of a run, read from its JSON into `arena`.
    read: *const fn (arena: Allocator, json: []const u8) Read,
    /// The job's `run`, with what `read` gave.
    call: *const fn (job: *anyopaque, ctx: *Context, payload: *const anyopaque) anyerror!void,
    /// The record a declared job wants; null without `.repeat`.
    wanted: ?*const fn (arena: Allocator, now: Instant, life: record.Life) error{ OutOfMemory, InvalidArgument }!Store.CreateRequest,
};

pub const Read = union(enum) {
    payload: *const anyopaque,
    /// The JSON does not read as the job's `Payload`.
    unreadable,
    out_of_memory,
};

/// A claimed record on its way from the poll to a slot.
pub const Item = struct {
    round: *Round,
    claimed: *const Store.Claimed,
    /// When its claim was sent, on the boot clock.
    sent: Io.Timestamp,
};

/// The memory of the records of one claim: the slot done with the last of
/// them frees it.
pub const Round = struct {
    arena: std.heap.ArenaAllocator,
    left: std.atomic.Value(u32) = .init(0),

    pub fn create(gpa: Allocator) error{OutOfMemory}!*Round {
        const r = try gpa.create(Round);
        r.* = .{ .arena = .init(gpa) };
        return r;
    }

    pub fn destroy(r: *Round, gpa: Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }

    pub fn release(r: *Round, gpa: Allocator) void {
        if (r.left.fetchSub(1, .acq_rel) == 1) r.destroy(gpa);
    }
};

gpa: Allocator,
io: Io,
store: Store,
options: Options,
/// "<options.instance>/<32 hex>", the owner of every claim.
instance: []u8,
/// The names of the jobs that a claim takes with any key, and only with
/// a key (`declared.split`).
any_key: []const []const u8,
keyed_only: []const []const u8,
/// What `start` hands over; nothing reads it before.
entries: []const Entry = &.{},

/// Guards the fields up to `outages`, for short sections without a call
/// of the store, a wait or a log line.
mutex: Io.Mutex = .init,
/// A stop was asked for: while starting, `start` goes on to draining.
stop_requested: bool = false,
/// When the stop began, on the awake clock.
stop_began: ?Io.Timestamp = null,
/// The earliest deadline of a `shutdown`, on the awake clock.
deadline: ?i96 = null,
/// The failures of the store in a row, by the kind of call, for the logs.
outages: std.EnumArray(Call, ?Outage) = .initFill(null),

state_value: std.atomic.Value(State) = .init(.configured),
/// The address of the worker since `start`: a moved worker panics.
home: std.atomic.Value(usize) = .init(0),
/// Tasks inside `wait`, `run` or `shutdown`: `deinit` panics while any is.
in_calls: std.atomic.Value(u32) = .init(0),
/// Not 0 once a stop began: the poll claims nothing more, and a slot
/// gives back what it takes from the queue without running it.
stopping: std.atomic.Value(u32) = .init(0),
/// The runs cancelled that have not ended yet.
cancelling: std.atomic.Value(u32) = .init(0),
/// The records claimed and not yet done with, queued or in a slot.
busy: std.atomic.Value(u32) = .init(0),
/// The tasks that still run, and one more for `start` while it spawns.
live: std.atomic.Value(u32) = .init(0),
tasks: Io.Group = .init,
/// Wakes the poll: a slot freed up, or a stop.
poll_wake: Io.Event = .unset,
/// Set once the worker stopped: every task of it ended.
stopped: Io.Event = .unset,
/// From the poll to the slots: `workers` items, which it never exceeds,
/// since a claim takes no more records than there are free slots.
queue: Io.Queue(Item) = undefined,
queue_buffer: []Item = &.{},
slots: []Slot = &.{},
counters: Counters = .{},

const Outage = struct { since: Io.Timestamp, tries: u64, warned: Io.Timestamp };

/// The calls of the store the worker makes.
pub const Call = enum { claim, renew, finish, create, get, update };

/// The longest wait handed to `std.Io` at once: some implementations
/// overflow on a far deadline.
pub const max_step: Duration = .fromSeconds(60 * 60);
/// How many races a write of `start` may lose before error.Contended.
const max_races = 8;

/// Checks the settings and names this instance, without I/O.
pub fn init(gpa: Allocator, io: Io, store: Store, any_key: []const []const u8, keyed_only: []const []const u8, options: Options) InitError!Engine {
    const d = options.diagnostics;
    if (options.workers == 0) return refuse(d, "workers: 0; a worker runs 1 or more jobs at once", .{});
    inline for (.{ "lease", "renew_every", "poll_every", "store_timeout", "shutdown_grace", "start_timeout", "max_backoff", "unreadable_limit" }) |name| {
        const value: Duration = @field(options, name);
        if (value.nanoseconds <= 0) return refuse(d, name ++ ": {f}; it must be more than zero", .{value});
    }
    if (options.lease.nanoseconds <= options.renew_every.nanoseconds *| 2)
        return refuse(d, "lease: {f}; it must be more than 2 × renew_every ({f})", .{ options.lease, options.renew_every });
    const rule = "an instance is 1–64 bytes of UTF-8 without NUL";
    const name = options.instance;
    if (name.len == 0) return refuse(d, "instance: empty; " ++ rule, .{});
    if (name.len > 64) return refuse(d, "instance: {d} bytes; " ++ rule, .{name.len});
    if (std.mem.findScalar(u8, name, 0) != null) return refuse(d, "instance: it holds a NUL; " ++ rule, .{});
    if (!std.unicode.utf8ValidateSlice(name)) return refuse(d, "instance: not UTF-8; " ++ rule, .{});
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const instance = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, std.fmt.bytesToHex(bytes, .lower) });
    return .{ .gpa = gpa, .io = io, .store = store, .options = options, .instance = instance, .any_key = any_key, .keyed_only = keyed_only };
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, format, args);
    return error.InvalidArgument;
}

/// In safe builds: a call on a worker moved after its `start`, or on
/// another `std.Io` than the one of `init`, panics.
pub fn checkUse(e: *const Engine, io: Io) void {
    if (!std.debug.runtime_safety) return;
    e.checkHome();
    // Two instances of one implementation share the table, so the
    // instance counts too.
    if (io.vtable != e.io.vtable or io.userdata != e.io.userdata)
        @panic("zefir-scheduler: a call on another std.Io than the worker's: pass the io of Worker.init");
}

fn checkHome(e: *const Engine) void {
    if (!std.debug.runtime_safety) return;
    const home = e.home.load(.monotonic);
    if (home != 0 and home != @intFromPtr(e)) @panic("zefir-scheduler: Worker moved after start(): keep it where start() ran");
}

pub fn state(e: *const Engine) State {
    e.checkHome();
    return e.state_value.load(.acquire);
}

pub fn isReady(e: *const Engine) bool {
    return e.state() == .running;
}

pub fn stats(e: *const Engine) Stats {
    e.checkHome();
    return e.counters.snapshot(e.options.workers);
}

/// Writes the records of the declared jobs, then starts the poll and the
/// slots. On an error nothing runs and the worker is stopped.
pub fn start(e: *Engine, io: Io, entries: []const Entry) StartError!void {
    {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        if (e.state_value.load(.monotonic) != .configured) return error.InvalidState;
        e.state_value.store(.starting, .release);
    }
    e.home.store(@intFromPtr(e), .monotonic);
    e.entries = entries;
    e.declare(io) catch |err| {
        e.markStopped(io);
        return err;
    };
    try e.spawn(io);
    const stop = stop: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        // A stop asked for while it started: straight to draining.
        if (e.state_value.load(.monotonic) == .starting) e.state_value.store(if (e.stop_requested) .draining else .running, .release);
        break :stop e.stop_requested;
    };
    log.info("{d} job type{s}, {d} worker{s}, instance {s}", .{
        e.entries.len,
        if (e.entries.len == 1) "" else "s",
        e.options.workers,
        if (e.options.workers == 1) "" else "s",
        e.instance,
    });
    if (stop) e.wakeAll(io);
}

/// The records of the declared jobs (none: no call of the store): a
/// job with `.repeat` gets its record, or the code's plan in the one
/// there; a job known without `.repeat` whose record is there finds it
/// parked, and it stays so.
fn declare(e: *Engine, io: Io) StartError!void {
    for (e.entries) |*entry| {
        if (entry.wanted != null) break;
    } else return;
    var arena: std.heap.ArenaAllocator = .init(e.gpa);
    defer arena.deinit();
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), e.options.start_timeout));
    for (e.entries) |*entry| {
        if (entry.wanted) |wanted| {
            try e.declareOne(io, ctx, arena.allocator(), wanted);
            continue;
        }
        var d: Diagnostics = .{};
        const ref: record.Ref = .{ .job = entry.policy.name, .key = "" };
        if (try e.tally(io, .get, e.store.get(io, ctx, &ref, .{ .allocator = arena.allocator(), .diagnostics = &d }), &d) == null) continue;
        _ = e.counters.undeclared.fetchAdd(1, .monotonic);
        log.warn("{s}: the record of a declaration this code does not have is parked, and no instance of it runs it; " ++
            "remove it with client.cancel(io, ctx, .declared({s}), .{{}})", .{ entry.policy.name, entry.type_name });
    }
}

fn declareOne(e: *Engine, io: Io, ctx: core.Context, a: Allocator, wanted: *const fn (Allocator, Instant, record.Life) error{ OutOfMemory, InvalidArgument }!Store.CreateRequest) StartError!void {
    var d: Diagnostics = .{};
    const options: Store.CallOptions = .{ .allocator = a, .diagnostics = &d };
    var life: record.Life = undefined;
    io.random(&life);
    const want = wanted(a, e.store.now(io), life) catch |err| {
        if (err == error.InvalidArgument) log.warn("a declared record cannot be written: a string of its Payload{{}} is not UTF-8, or its schedule has no run within 9 years", .{});
        return err;
    };
    const ref: record.Ref = .{ .job = want.job, .key = "" };
    var lost: u32 = 0;
    while (lost <= max_races) : (lost += 1) {
        switch (try e.tally(io, .create, e.store.create(io, ctx, &want, options), &d)) {
            .created, .replaced => return log.info("{s}: declared, {s}", .{ want.job, want.plan }),
            .existing => {},
        }
        var current = (try e.tally(io, .get, e.store.get(io, ctx, &ref, options), &d)) orelse continue;
        // A finished record goes again to create, which replaces it.
        while (current.state != .succeeded and current.state != .failed) : (lost += 1) {
            const patch = declared.reconcile(&current, want.plan, want.run_at) orelse return;
            if (lost == max_races) return error.Contended;
            var tag: Store.Tag = undefined;
            io.random(&tag);
            const request: Store.UpdateRequest = .{ .ref = ref, .expect = .{ .life = current.life, .revision = current.revision, .state = current.state }, .set = patch, .tag = tag };
            switch (try e.tally(io, .update, e.store.update(io, ctx, &request, options), &d)) {
                .updated => return log.info("{s}: the declared record takes the plan of the code, {s}", .{ want.job, want.plan }),
                .conflict => |now| current = now,
                .not_found => break,
            }
        }
    }
    return error.Contended;
}

/// The slots, then the poll, each a task of `tasks`. When the Io has no
/// task for one, those that run stop, and so does the worker.
fn spawn(e: *Engine, io: Io) StartError!void {
    const n = e.options.workers;
    e.queue_buffer = e.gpa.alloc(Item, n) catch {
        e.markStopped(io);
        return error.OutOfMemory;
    };
    e.queue = .init(e.queue_buffer);
    e.slots = e.gpa.alloc(Slot, n) catch {
        e.markStopped(io);
        return error.OutOfMemory;
    };
    for (e.slots) |*s| s.* = .init(e, io);
    // The reference of `start`: no task stops the worker before all run.
    e.live.store(1, .release);
    const spawned = for (e.slots) |*s| {
        _ = e.live.fetchAdd(1, .acq_rel);
        e.tasks.concurrent(io, Slot.loop, .{s}) catch {
            _ = e.live.fetchSub(1, .acq_rel);
            break false;
        };
    } else poll_task: {
        _ = e.live.fetchAdd(1, .acq_rel);
        e.tasks.concurrent(io, poll.loop, .{e}) catch {
            _ = e.live.fetchSub(1, .acq_rel);
            break :poll_task false;
        };
        break :poll_task true;
    };
    if (!spawned) {
        // No poll runs: close its queue, and the slots that run end.
        e.requestStop(io);
        e.queue.close(io);
    }
    e.taskEnded(io);
    if (spawned) return;
    e.stopped.waitUncancelable(io);
    return error.ConcurrencyUnavailable;
}

/// One of the tasks ended; the last stops the worker.
pub fn taskEnded(e: *Engine, io: Io) void {
    if (e.live.fetchSub(1, .acq_rel) == 1) e.markStopped(io);
}

fn markStopped(e: *Engine, io: Io) void {
    const was = was: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        break :was e.state_value.swap(.stopped, .acq_rel);
    };
    if (was == .running or was == .draining) log.info("stopped", .{});
    e.stopped.set(io);
}

/// Stops claiming and begins the stop; from any task, without waiting.
pub fn requestStop(e: *Engine, io: Io) void {
    const wake = wake: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        switch (e.state_value.load(.monotonic)) {
            .configured => {
                e.state_value.store(.stopped, .release);
                e.stopped.set(io);
                break :wake false;
            },
            // `start` wakes the tasks once they run.
            .starting => {
                e.beginStop(io);
                break :wake false;
            },
            .running => {
                e.state_value.store(.draining, .release);
                e.beginStop(io);
                break :wake true;
            },
            .draining, .stopped => break :wake false,
        }
    };
    if (!wake) return;
    log.info("stopping", .{});
    e.wakeAll(io);
}

/// Under `mutex`.
fn beginStop(e: *Engine, io: Io) void {
    e.stop_requested = true;
    if (e.stop_began == null) e.stop_began = Io.Clock.awake.now(io);
    // A read-modify-write, as the reads of the tasks after their resets:
    // a task that read 0 sees the wake that follows.
    _ = e.stopping.swap(1, .acq_rel);
}

/// Wakes the poll and every slot; only once the tasks run.
fn wakeAll(e: *Engine, io: Io) void {
    e.poll_wake.set(io);
    for (e.slots) |*s| s.wake.set(io);
}

pub fn isStopping(e: *Engine) bool {
    return e.stopping.fetchAdd(0, .acq_rel) != 0;
}

/// How much earlier than its deadline `shutdown` returns, so that the
/// caller has time for what comes after.
const reserve: Duration = .fromMilliseconds(250);

/// `requestStop`, and a wait for the stop until 250 ms before `deadline`,
/// which also cuts the grace (`graceEnd`).
pub fn shutdown(e: *Engine, io: Io, deadline: Io.Clock.Timestamp) ShutdownError!void {
    _ = e.in_calls.fetchAdd(1, .acq_rel);
    defer _ = e.in_calls.fetchSub(1, .acq_rel);
    const due = deadline.toClock(io, .awake).raw.nanoseconds;
    const draining = draining: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        e.deadline = if (e.deadline) |given| @min(given, due) else due;
        break :draining e.state_value.load(.monotonic) == .draining;
    };
    e.requestStop(io);
    // The runs of a stop that began before look at their grace again.
    if (draining) e.wakeAll(io);
    const until = due -| reserve.nanoseconds;
    while (!e.stopped.isSet()) {
        const now = Io.Clock.awake.now(io).nanoseconds;
        if (now >= until) break;
        const step = @min(until, now +| max_step.nanoseconds);
        e.stopped.waitTimeout(io, .{ .deadline = .{ .raw = .{ .nanoseconds = step }, .clock = .awake } }) catch |err| switch (err) {
            error.Canceled => |c| return c,
            error.Timeout => {},
        };
    } else return;
    log.warn("the worker did not stop by its deadline: {d} runs have not ended since their cancel; it stays draining", .{e.cancelling.load(.acquire)});
    return error.ShutdownTimeout;
}

/// Waits until the worker stopped.
pub fn wait(e: *Engine, io: Io) WaitError!void {
    if (e.state_value.load(.acquire) == .configured) return error.InvalidState;
    _ = e.in_calls.fetchAdd(1, .acq_rel);
    defer _ = e.in_calls.fetchSub(1, .acq_rel);
    try e.stopped.wait(io);
}

/// Stops the worker if it runs, waits for its tasks without a limit and
/// frees it.
pub fn deinit(e: *Engine, io: Io) void {
    if (e.in_calls.load(.acquire) != 0)
        @panic("zefir-scheduler: Worker.deinit() while a task is in wait, run or shutdown: let it return first");
    // No cancelation point: a cancelation request of the caller stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    e.requestStop(io);
    e.tasks.await(io) catch {};
    for (e.slots) |*s| s.deinit();
    e.gpa.free(e.slots);
    e.gpa.free(e.queue_buffer);
    e.gpa.free(e.instance);
    e.* = undefined;
}

/// The end of the grace of the stop, on the awake clock: `shutdown_grace`
/// after it began, but no later than 2 s and 250 ms before the deadline
/// of a `shutdown`, for the cancels, the outcomes and the caller; never
/// before it began. null while no stop began.
pub fn graceEnd(e: *Engine, io: Io) ?i96 {
    if (!e.isStopping()) return null;
    e.mutex.lockUncancelable(io);
    defer e.mutex.unlock(io);
    const began = (e.stop_began orelse return null).nanoseconds;
    const grace = began +| e.options.shutdown_grace.nanoseconds;
    const due = e.deadline orelse return grace;
    return @min(grace, @max(due -| (outcome_budget.nanoseconds + reserve.nanoseconds), began));
}

/// The time a stop leaves for the cancels and the outcomes after its grace.
const outcome_budget: Duration = .fromSeconds(2);

/// The last moment of a stop to write outcomes in, on the awake clock:
/// 250 ms before the deadline of a `shutdown`, else 2 s after the grace;
/// null while no stop began.
pub fn stopEnd(e: *Engine, io: Io) ?i96 {
    const grace = e.graceEnd(io) orelse return null;
    const due = e.deadlineOf(io) orelse return grace +| outcome_budget.nanoseconds;
    return due -| reserve.nanoseconds;
}

fn deadlineOf(e: *Engine, io: Io) ?i96 {
    e.mutex.lockUncancelable(io);
    defer e.mutex.unlock(io);
    return e.deadline;
}

/// The entry of the job `name`.
pub fn entryOf(e: *const Engine, name: []const u8) ?*const Entry {
    for (e.entries) |*entry| {
        if (std.mem.eql(u8, entry.policy.name, name)) return entry;
    }
    return null;
}

/// The context of a call of the store by the poll or a slot: never the
/// handler's token, a deadline of `store_timeout`, and no later than 250 ms
/// before the deadline of a `shutdown`.
pub fn callContext(e: *Engine, io: Io) core.Context {
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), e.options.store_timeout));
    const due = e.deadlineOf(io) orelse return ctx;
    return ctx.withDeadline(.at(.{ .nanoseconds = due -| reserve.nanoseconds }));
}

/// Counts what a call of the store gave: an error, or an answer.
pub fn tally(e: *Engine, io: Io, comptime what: Call, result: anytype, d: *const Diagnostics) @TypeOf(result) {
    if (result) |_| e.storeAnswered(io, what) else |err| e.storeFailed(io, what, err, d);
    return result;
}

/// Logs the first failure of a kind of call, then once a minute while it
/// goes on failing: a store that takes claims and refuses renewals is
/// still failing.
fn storeFailed(e: *Engine, io: Io, comptime what: Call, err: anyerror, d: *const Diagnostics) void {
    e.counters.add(.store_errors, 1);
    e.counters.store_down.store(true, .release);
    const now = Io.Clock.awake.now(io);
    const tries: u64 = tries: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        const slot = e.outages.getPtr(what);
        const o = if (slot.*) |*o| o else {
            slot.* = .{ .since = now, .tries = 1, .warned = now };
            break :tries 1;
        };
        o.tries += 1;
        if (now.nanoseconds -| o.warned.nanoseconds < std.time.ns_per_min) break :tries 0;
        o.warned = now;
        break :tries o.tries;
    };
    switch (tries) {
        0 => {},
        1 => log.warn("the store fails: " ++ @tagName(what) ++ ": error.{t}: {s}", .{ err, d.message() }),
        else => log.warn("the store still fails, {d} tries: " ++ @tagName(what) ++ ": error.{t}: {s}", .{ tries, err, d.message() }),
    }
}

fn storeAnswered(e: *Engine, io: Io, comptime what: Call) void {
    e.counters.store_down.store(false, .release);
    const since = since: {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        const slot = e.outages.getPtr(what);
        const o = slot.* orelse break :since null;
        slot.* = null;
        break :since o.since;
    };
    const began = since orelse return;
    log.warn("the store answers " ++ @tagName(what) ++ " again after {f}", .{began.durationTo(Io.Clock.awake.now(io))});
}
