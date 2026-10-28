//! The poll of a worker: one task that claims the due records of the
//! worker's jobs, no more than its free slots, and queues them for the
//! slots. Once a stop began it claims nothing more and closes the queue.
//! Internal to the module.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Diagnostics = @import("../Diagnostics.zig");
const Store = @import("../Store.zig");
const Engine = @import("Engine.zig");

const log = std.log.scoped(.scheduler);

/// The shortest pause after a claim that took fewer records than it could.
const min_pause: Duration = .fromMilliseconds(10);

pub fn loop(e: *Engine) void {
    const io = e.io;
    // Nothing cancels this task: it ends by the stop.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    defer e.taskEnded(io);
    // The slots end once the queue is empty and closed.
    defer e.queue.close(io);
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var failures: u32 = 0;
    var due = Io.Clock.awake.now(io);
    var round: ?*Engine.Round = null;
    defer if (round) |r| r.destroy(e.gpa);
    while (waitUntil(e, io, due) and waitFree(e, io)) {
        const r = round orelse Engine.Round.create(e.gpa) catch {
            due = after(io, e.options.poll_every);
            continue;
        };
        round = r;
        const free = e.options.workers - e.busy.load(.acquire);
        var tag: Store.Tag = undefined;
        io.random(&tag);
        var d: Diagnostics = .{};
        const request: Store.ClaimRequest = .{ .owner = e.instance, .any_key = e.any_key, .keyed_only = e.keyed_only, .max = free, .lease = e.options.lease, .tag = tag };
        const sent = Io.Clock.boot.now(io);
        const options: Store.CallOptions = .{ .allocator = r.arena.allocator(), .diagnostics = &d };
        const result = e.tally(io, .claim, e.store.claim(io, e.callContext(io), &request, options), &d) catch {
            _ = r.arena.reset(.retain_capacity);
            failures +|= 1;
            due = after(io, jitter(random, backoff(e.options, failures)));
            continue;
        };
        failures = 0;
        if (result.claimed.len == 0) {
            _ = r.arena.reset(.retain_capacity);
        } else {
            const n: u32 = @intCast(result.claimed.len);
            r.left.store(n, .release);
            round = null;
            _ = e.busy.fetchAdd(n, .acq_rel);
            e.counters.add(.claimed, n);
            for (result.claimed) |*c| {
                if (c.took_over) |prior| {
                    e.counters.add(.taken_over, 1);
                    log.warn("{s}/{s}: took over the claim of {s}, whose lease ended without a renewal", .{ c.record.job, c.record.key, prior.owner });
                }
                log.debug("claimed {s}/{s}: attempt {d}, fence {d}", .{ c.record.job, c.record.key, c.record.attempt, c.record.fence });
                e.queue.putOneUncancelable(io, .{ .round = r, .claimed = c, .sent = sent }) catch {
                    // Only this task closes the queue, after its loop.
                    r.release(e.gpa);
                    _ = e.busy.fetchSub(1, .acq_rel);
                };
            }
        }
        if (result.claimed.len == free) {
            due = Io.Clock.awake.now(io);
        } else {
            const next = if (result.next_in) |x| @min(x.nanoseconds, e.options.poll_every.nanoseconds) else e.options.poll_every.nanoseconds;
            due = after(io, .fromNanoseconds(@max(jitter(random, .fromNanoseconds(next)).nanoseconds, min_pause.nanoseconds)));
        }
    }
}

/// The moment `d` from now on the awake clock.
fn after(io: Io, d: Duration) Io.Timestamp {
    return .{ .nanoseconds = Io.Clock.awake.now(io).nanoseconds +| @max(d.nanoseconds, 0) };
}

/// The pause after `failures` failed claims in a row: `poll_every ×
/// 2^failures`, at most `max_backoff`.
pub fn backoff(options: Engine.Options, failures: u32) Duration {
    const most = options.max_backoff.nanoseconds;
    var ns = options.poll_every.nanoseconds;
    var k: u32 = 0;
    while (k < failures and ns < most) : (k += 1) ns *|= 2;
    return .fromNanoseconds(@min(ns, most));
}

/// `d` give or take a random 10 %, so that instances that started
/// together poll apart.
pub fn jitter(random: std.Random, d: Duration) Duration {
    const ns: i128 = @max(d.nanoseconds, 0);
    const spread = @divTrunc(ns * random.uintAtMost(u32, 1000), 5000);
    return .fromNanoseconds(@intCast(ns - @divTrunc(ns, 10) + spread));
}

/// Waits until `due`; false once a stop began.
fn waitUntil(e: *Engine, io: Io, due: Io.Timestamp) bool {
    while (true) {
        e.poll_wake.reset();
        if (e.isStopping()) return false;
        const now = Io.Clock.awake.now(io).nanoseconds;
        if (now >= due.nanoseconds) return true;
        const until = @min(due.nanoseconds, now +| Engine.max_step.nanoseconds);
        e.poll_wake.waitTimeout(io, .{ .deadline = .{ .raw = .{ .nanoseconds = until }, .clock = .awake } }) catch {};
    }
}

/// Waits until a slot is free; false once a stop began.
fn waitFree(e: *Engine, io: Io) bool {
    while (true) {
        e.poll_wake.reset();
        if (e.isStopping()) return false;
        // A read-modify-write after the reset: a slot that frees up after
        // it sets the event again.
        if (e.busy.fetchAdd(0, .acq_rel) < e.options.workers) return true;
        e.poll_wake.waitTimeout(io, .{ .duration = .{ .raw = Engine.max_step, .clock = .awake } }) catch {};
    }
}
