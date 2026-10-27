//! A slot of a worker: a task that takes the claimed records from the
//! queue of the poll one at a time, checks each, runs its job's `run` in a
//! task of its own, and records the outcome on condition of its claim.
//! Internal to the module.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const Diagnostics = @import("../Diagnostics.zig");
const Store = @import("../Store.zig");
const Schedule = @import("../schedule/Schedule.zig");
const record = @import("../record.zig");
const run_context = @import("../Context.zig");
const Engine = @import("Engine.zig");
const policy = @import("policy.zig");
const transition = @import("transition.zig");
const run_info = @import("run_info.zig");
const Ending = transition.Ending;

const Slot = @This();
const log = std.log.scoped(.scheduler);

engine: *Engine,
/// Wakes the slot while a run goes: its handler ended, or a stop.
wake: Io.Event = .unset,
/// Not 0 once the handler of the run ended.
done: std.atomic.Value(u32) = .init(0),
/// The memory of one record: its payload, its `RunInfo`, what the handler
/// allocates, then the calls of its outcome. Reset after each record.
arena: std.heap.ArenaAllocator,
/// The memory of the renewals, while the handler holds `arena`.
calls: std.heap.ArenaAllocator,
prng: std.Random.DefaultPrng,
/// What the handler's task reads, set before it starts.
token: core.CancellationToken = .init,
context: run_context.State = undefined,
entry: *const Engine.Entry = undefined,
payload: *const anyopaque = undefined,

/// How many times in a row a finish may meet a change of the client.
const max_changes = 8;
/// How much of its arena a slot keeps between records.
const kept_bytes = 64 * 1024;

pub fn init(e: *Engine, io: Io) Slot {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    return .{ .engine = e, .arena = .init(e.gpa), .calls = .init(e.gpa), .prng = .init(seed) };
}

pub fn deinit(s: *Slot) void {
    s.arena.deinit();
    s.calls.deinit();
}

/// The task of a slot: the records of the queue, until it is closed and
/// empty.
pub fn loop(s: *Slot) void {
    const e = s.engine;
    const io = e.io;
    // Nothing cancels this task, so nothing cancels the calls of the
    // store it makes for its claims.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    defer e.taskEnded(io);
    while (e.queue.getOneUncancelable(io)) |item| {
        s.process(item);
        item.round.release(e.gpa);
        _ = s.arena.reset(.{ .retain_with_limit = kept_bytes });
        _ = e.busy.fetchSub(1, .acq_rel);
        e.poll_wake.set(io);
    } else |_| {}
}

fn process(s: *Slot, item: Engine.Item) void {
    const r = &item.claimed.record;
    const entry = s.engine.entryOf(r.job) orelse {
        log.warn("{s}/{s}: a claim gave a job this worker does not run; it goes back when its lease ends", .{ r.job, r.key });
        return;
    };
    const ending = s.check(entry, item.claimed, item.sent);
    log.debug("{s}/{s}: {t}", .{ r.job, r.key, ending });
    s.finish(entry, item.claimed, ending);
}

/// The checks before a run, in order, then the run: a stop gives the
/// record back; a plan that does not read here, an abandoned attempt that
/// was the last, a run of a repeating job too late for `.skip` and a
/// payload that does not read here run nothing.
fn check(s: *Slot, entry: *const Engine.Entry, claimed: *const Store.Claimed, sent: Io.Timestamp) Ending {
    const e = s.engine;
    const r = &claimed.record;
    const p = &entry.policy;
    const attempts = p.attempts(r.plan);
    const last_lost = claimed.took_over != null and r.attempt > attempts;
    if (e.isStopping()) return if (last_lost) .abandoned_last else .not_started;
    const plan: ?Schedule = if (r.plan.len == 0) null else Schedule.parse(r.plan, null) catch return .{ .unreadable = .schedule };
    if (last_lost) return .abandoned_last;
    // A claimed record has its claimed_at.
    const claimed_at = r.claimed_at orelse r.scheduled_at;
    if (plan != null and policy.late(p.misfire, r.scheduled_at, claimed_at)) return .skipped;
    const payload = switch (entry.read(s.arena.allocator(), r.payload)) {
        .payload => |x| x,
        .unreadable => return .{ .unreadable = .payload },
        .out_of_memory => return .{ .failed = error.OutOfMemory },
    };
    const missed = if (plan) |x| policy.missed(x, r.scheduled_at, claimed_at) else 0;
    return s.run(entry, r, payload, attempts, missed, sent);
}

/// Runs the handler in a task of its own and waits for its end, renewing
/// the lease every `renew_every` from the last confirmed claim or renewal
/// (`sent`, then each renewal's send time, on the boot clock). The local
/// deadline of the lease, its last confirmation plus `lease` −
/// `renew_every` (А5), the timeout of the job, the end of the grace of a
/// stop, a lease taken over and a removed record cancel the run: the
/// token, then the task.
fn run(s: *Slot, entry: *const Engine.Entry, r: *const record.Record, payload: *const anyopaque, attempts: u32, missed: u32, sent: Io.Timestamp) Ending {
    const e = s.engine;
    const io = e.io;
    const o = &e.options;
    const info = run_info.runInfo(s.arena.allocator(), r, attempts, missed, e.instance) catch return .{ .failed = error.OutOfMemory };
    s.token = .init;
    s.context = .{ .io = io, .operation = run_info.operation(io, r.trace, entry.policy.timeout, &s.token), .arena = s.arena.allocator(), .info = info };
    s.entry = entry;
    s.payload = payload;
    s.done.store(0, .release);
    _ = e.counters.running.fetchAdd(1, .monotonic);
    defer _ = e.counters.running.fetchSub(1, .monotonic);
    var future = io.concurrent(handler, .{s}) catch return .{ .failed = error.ConcurrencyUnavailable };
    const timeout: ?i96 = if (s.context.operation.deadline) |d| d.expires.nanoseconds else null;
    var confirmed = sent.nanoseconds;
    var renew_at = confirmed +| o.renew_every.nanoseconds;
    const stop: ?Ending = while (true) {
        s.wake.reset();
        // A read-modify-write after the reset: a handler that ends after
        // it sets the event again.
        if (s.done.fetchAdd(0, .acq_rel) != 0) break null;
        const boot = Io.Clock.boot.now(io).nanoseconds;
        const awake = Io.Clock.awake.now(io).nanoseconds;
        const local = confirmed +| o.lease.nanoseconds -| o.renew_every.nanoseconds;
        if (timeout) |t| if (awake >= t) break .timed_out;
        if (boot >= local) break .{ .interrupted = .lease_unconfirmed };
        const grace = e.graceEnd(io);
        if (grace) |g| if (awake >= g) break .{ .interrupted = .shutdown };
        if (boot >= renew_at) {
            switch (s.renew(r, local)) {
                .renewed => |t| {
                    confirmed = t;
                    renew_at = t +| o.renew_every.nanoseconds;
                },
                // Again a quarter of renew_every later, until the local deadline.
                .failed => renew_at = boot +| @divTrunc(o.renew_every.nanoseconds, 4),
                .lost => break .lost,
                .removed => break .removed,
            }
            continue;
        }
        // The awake times as times of the boot clock, which goes on while
        // the machine sleeps: a wake-up after a sleep looks again.
        var until = @min(renew_at, local, boot +| Engine.max_step.nanoseconds);
        if (timeout) |t| until = @min(until, boot +| (t -| awake));
        if (grace) |g| until = @min(until, boot +| (g -| awake));
        s.wake.waitTimeout(io, .{ .deadline = .{ .raw = .{ .nanoseconds = until }, .clock = .boot } }) catch {};
    };
    const result = if (stop == null) future.await(io) else cancelled: {
        s.token.cancel();
        _ = e.cancelling.fetchAdd(1, .acq_rel);
        defer _ = e.cancelling.fetchSub(1, .acq_rel);
        break :cancelled future.cancel(io);
    };
    const c = &e.counters;
    if (stop) |why| {
        switch (why) {
            .timed_out => {
                c.add(.failed, 1);
                c.add(.timed_out, 1);
                log.warn("{s}/{s}: the run passed its timeout and was cancelled", .{ r.job, r.key });
            },
            .interrupted => |how| switch (how) {
                .shutdown => log.info("{s}/{s}: the run was cancelled at the end of the grace of the stop", .{ r.job, r.key }),
                .lease_unconfirmed => {
                    c.add(.lost, 1);
                    log.warn("{s}/{s}: the lease could not be confirmed; the run was cancelled before another instance could take the job", .{ r.job, r.key });
                },
            },
            .lost => {
                c.add(.lost, 1);
                log.warn("{s}/{s}: another instance took the lease over; the run was cancelled", .{ r.job, r.key });
            },
            .removed => {
                c.add(.removed, 1);
                log.warn("{s}/{s}: the record was removed; the run was cancelled", .{ r.job, r.key });
            },
            else => {},
        }
        return why;
    }
    if (result) |_| {
        c.add(.succeeded, 1);
        return .succeeded;
    } else |err| {
        c.add(.failed, 1);
        // An error once its time is up is the timeout, as the handler saw it.
        if (timeout) |t| if (Io.Clock.awake.now(io).nanoseconds >= t) {
            c.add(.timed_out, 1);
            return .timed_out;
        };
        return .{ .failed = err };
    }
}

const Renewed = union(enum) { renewed: i96, failed, lost, removed };

/// One renewal, which waits no longer than the local deadline `local`.
fn renew(s: *Slot, r: *const record.Record, local: i96) Renewed {
    const e = s.engine;
    const io = e.io;
    defer _ = s.calls.reset(.retain_capacity);
    const t = Io.Clock.boot.now(io).nanoseconds;
    const budget: Io.Duration = .fromNanoseconds(@min(local -| t, e.options.store_timeout.nanoseconds));
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), budget));
    var d: Diagnostics = .{};
    const request: Store.RenewRequest = .{ .ref = .{ .job = r.job, .key = r.key }, .life = r.life, .owner = e.instance, .fence = r.fence, .lease = e.options.lease };
    const result = e.tally(io, "renew", e.store.renew(io, ctx, &request, .{ .allocator = s.calls.allocator(), .diagnostics = &d }), &d) catch return .failed;
    return switch (result) {
        .renewed => .{ .renewed = t },
        .lost => .lost,
        .removed => .removed,
    };
}

/// The task of a run: the job's `run`, then the slot learns it ended.
fn handler(s: *Slot) anyerror!void {
    defer {
        _ = s.done.swap(1, .acq_rel);
        s.wake.set(s.engine.io);
    }
    return s.entry.call(s.entry.job, run_context.of(&s.context), s.payload);
}

/// Sends the transition of `ending` to the store, on condition of the
/// claim; a change of the client that came meanwhile is decided again.
fn finish(s: *Slot, entry: *const Engine.Entry, claimed: *const Store.Claimed, ending: Ending) void {
    const e = s.engine;
    const io = e.io;
    const r = &claimed.record;
    var current: ?record.Record = null;
    var changes: u32 = 0;
    while (true) {
        const d = transition.decide(.{
            .policy = &entry.policy,
            .claimed = r,
            .took_over = claimed.took_over,
            .ending = ending,
            .current = if (current) |*c| c else null,
            .instance = e.instance,
            .unreadable_limit = e.options.unreadable_limit,
            .random = s.prng.random(),
        });
        // Taken over or removed: the store refuses the transition, and
        // only rows are left to write.
        if ((ending == .lost or ending == .removed) and d.runs().len == 0) return;
        var tag: Store.Tag = undefined;
        io.random(&tag);
        const request: Store.FinishRequest = .{
            .ref = .{ .job = r.job, .key = r.key },
            .life = r.life,
            .owner = e.instance,
            .fence = r.fence,
            .revision = if (current) |c| c.revision else r.revision,
            .tag = tag,
            .next = d.next,
            .last = d.last,
            .history = .{ .runs = d.runs(), .keep = d.keep },
        };
        var diag: Diagnostics = .{};
        const options: Store.CallOptions = .{ .allocator = s.arena.allocator(), .diagnostics = &diag };
        const result = e.tally(io, "finish", e.store.finish(io, e.callContext(io), &request, options), &diag) catch return;
        switch (result) {
            .done => return s.account(r, &d),
            .lost => {
                if (ending != .lost and ending != .removed)
                    log.warn("{s}/{s}: the store refused the outcome of the run: the claim was taken over or the record removed meanwhile", .{ r.job, r.key });
                return;
            },
            .changed => |now| {
                changes += 1;
                if (changes > max_changes) {
                    log.warn("{s}/{s}: the record changed {d} times while its outcome was written; it goes back when its lease ends", .{ r.job, r.key, max_changes });
                    return;
                }
                current = now;
            },
        }
    }
}

/// The counters and the logs of a transition the store took.
fn account(s: *Slot, r: *const record.Record, d: *const transition.Decision) void {
    const c = &s.engine.counters;
    switch (d.event) {
        .none => {},
        .retry => log.info("{s}/{s}: attempt {d} failed ({s}); it runs again after a pause", .{ r.job, r.key, r.attempt, errorOf(d) }),
        .gave_up, .unreadable_gave_up, .no_next_run => {
            c.add(.gave_up, 1);
            log.warn("{s}/{s}: the job ended failed ({s})", .{ r.job, r.key, errorOf(d) });
        },
        .coalesced => {
            c.add(.coalesced, 1);
            log.info("{s}/{s}: one run stood for the runs it missed", .{ r.job, r.key });
        },
        .skipped => {
            c.add(.skipped, 1);
            log.info("{s}/{s}: a run later than its misfire threshold was skipped", .{ r.job, r.key });
        },
        .unreadable => {
            c.add(.unreadable, 1);
            log.warn("{s}/{s}: this instance cannot read its payload or its schedule; it goes back for another instance", .{ r.job, r.key });
        },
    }
}

fn errorOf(d: *const transition.Decision) []const u8 {
    const last = d.last orelse return "no error";
    return last.error_name orelse @tagName(last.outcome);
}
