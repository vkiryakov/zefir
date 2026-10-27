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
    return .{ .engine = e, .arena = .init(e.gpa), .prng = .init(seed) };
}

pub fn deinit(s: *Slot) void {
    s.arena.deinit();
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
    const ending = s.check(entry, item.claimed);
    log.debug("{s}/{s}: {t}", .{ r.job, r.key, ending });
    s.finish(entry, item.claimed, ending);
}

/// The checks before a run, in order, then the run: a stop gives the
/// record back; a plan that does not read here, an abandoned attempt that
/// was the last, a run of a repeating job too late for `.skip` and a
/// payload that does not read here run nothing.
fn check(s: *Slot, entry: *const Engine.Entry, claimed: *const Store.Claimed) Ending {
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
    return s.run(entry, r, payload, attempts, missed);
}

/// Runs the handler in a task of its own and waits for its end.
fn run(s: *Slot, entry: *const Engine.Entry, r: *const record.Record, payload: *const anyopaque, attempts: u32, missed: u32) Ending {
    const e = s.engine;
    const io = e.io;
    const info = run_info.runInfo(s.arena.allocator(), r, attempts, missed, e.instance) catch return .{ .failed = error.OutOfMemory };
    s.token = .init;
    s.context = .{ .io = io, .operation = run_info.operation(io, r.trace, entry.policy.timeout, &s.token), .arena = s.arena.allocator(), .info = info };
    s.entry = entry;
    s.payload = payload;
    s.done.store(0, .release);
    _ = e.counters.running.fetchAdd(1, .monotonic);
    defer _ = e.counters.running.fetchSub(1, .monotonic);
    var future = io.concurrent(handler, .{s}) catch return .{ .failed = error.ConcurrencyUnavailable };
    while (true) {
        s.wake.reset();
        if (s.done.fetchAdd(0, .acq_rel) != 0) break;
        s.wake.waitTimeout(io, .{ .duration = .{ .raw = Engine.max_step, .clock = .awake } }) catch {};
    }
    const ending: Ending = if (future.await(io)) |_| .succeeded else |err| .{ .failed = err };
    switch (ending) {
        .succeeded => e.counters.add(.succeeded, 1),
        else => e.counters.add(.failed, 1),
    }
    return ending;
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
