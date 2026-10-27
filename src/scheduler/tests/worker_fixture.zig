//! What the tests of scheduler.Worker share: a job type for any
//! declaration whose runs a `Probe` watches and steers, a store (a
//! FaultyStore over a MemoryStore) with a client, and waits that loop on
//! the clock.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const scheduler = @import("../root.zig");

pub const io = testing.io;

/// Settings with short times that hold on a slow machine: a lease of 3 s,
/// renewed every second, a poll every 100 ms.
pub const quick: scheduler.Worker(struct {}).Options = .{
    .lease = .fromSeconds(3),
    .renew_every = .fromSeconds(1),
    .poll_every = .fromMilliseconds(100),
};

/// Watches the runs of a job and steers them: set the plain fields before
/// the start of the worker.
pub const Probe = struct {
    /// How long a run holds; it ends early when it is cancelled.
    hold: Io.Duration = .zero,
    /// What every run returns.
    fail: ?anyerror = null,
    /// A run cancelled while this is set holds on until it drops.
    deaf: std.atomic.Value(bool) = .init(false),
    runs: std.atomic.Value(u32) = .init(0),
    ended: std.atomic.Value(u32) = .init(0),
    active: std.atomic.Value(u32) = .init(0),
    most: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    /// Of the latest run.
    attempt: std.atomic.Value(u32) = .init(0),
    missed: std.atomic.Value(u32) = .init(0),
    /// Of the latest run, on the awake clock.
    started: std.atomic.Value(i64) = .init(0),
    stopped: std.atomic.Value(i64) = .init(0),

    fn run(p: *Probe, ctx: *scheduler.Context) !void {
        const task_io = ctx.io();
        p.attempt.store(ctx.info().attempt, .release);
        p.missed.store(ctx.info().missed, .release);
        p.started.store(nowMs(), .release);
        _ = p.most.fetchMax(p.active.fetchAdd(1, .acq_rel) + 1, .acq_rel);
        _ = p.runs.fetchAdd(1, .acq_rel);
        defer {
            _ = p.active.fetchSub(1, .acq_rel);
            p.stopped.store(nowMs(), .release);
            _ = p.ended.fetchAdd(1, .acq_rel);
        }
        if (p.hold.nanoseconds > 0) task_io.sleep(p.hold, .awake) catch |err| {
            _ = p.cancelled.fetchAdd(1, .acq_rel);
            if (!p.deaf.load(.acquire)) return err;
            while (p.deaf.load(.acquire)) task_io.sleep(.fromMilliseconds(10), .awake) catch {};
        };
        if (p.fail) |err| return err;
    }
};

/// A job type of the declaration `decl`, whose runs `probe` watches.
pub fn Job(comptime decl: scheduler.Job) type {
    return struct {
        probe: *Probe,

        pub const scheduler_job: scheduler.Job = decl;
        pub const Payload = struct { n: u64 = 0 };

        pub fn run(self: *@This(), ctx: *scheduler.Context, payload: Payload) !void {
            _ = payload;
            return self.probe.run(ctx);
        }
    };
}

pub fn nowMs() i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Waits until `counter` reaches `n`, for at most `seconds`.
pub fn reach(counter: *const std.atomic.Value(u32), n: u32, seconds: i64) !void {
    const give_up = nowMs() + seconds * 1000;
    while (counter.load(.acquire) < n) {
        if (nowMs() >= give_up) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// Waits until the counter `field` of the stats of the worker `w` reaches
/// `n`, for at most `seconds`. A slot counts the event of a transition only
/// once the store took it, after the record changed: a test that saw the
/// record change waits for the count.
pub fn counted(w: anytype, comptime field: []const u8, n: u64, seconds: i64) !void {
    const give_up = nowMs() + seconds * 1000;
    while (@field(w.stats(), field) < n) {
        if (nowMs() >= give_up) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// A store with faults on demand over a MemoryStore, and a client of the
/// MemoryStore itself, which the faults do not touch. Made in place.
pub const Fixture = struct {
    memory: scheduler.MemoryStore,
    faulty: scheduler.testing.FaultyStore,
    client: scheduler.Client,
    arena: std.heap.ArenaAllocator,

    pub fn init(f: *Fixture) void {
        f.memory = .init(testing.allocator, io, .{});
        f.faulty = .init(f.memory.store());
        f.client = .init(testing.allocator, io, f.memory.store(), .{});
        f.arena = .init(testing.allocator);
    }

    pub fn deinit(f: *Fixture) void {
        f.memory.deinit();
        f.arena.deinit();
    }

    /// The store of the workers.
    pub fn store(f: *Fixture) scheduler.Store {
        return f.faulty.store();
    }

    pub fn schedule(f: *Fixture, comptime J: type, key: []const u8, when: scheduler.When) !void {
        try testing.expectEqual(scheduler.Client.Scheduled.created, try f.client.schedule(io, .root, J, .{ .key = key, .when = when, .payload = .{} }, .{}));
    }

    pub fn get(f: *Fixture, ref: scheduler.Ref) !?scheduler.Record {
        return f.client.get(io, .root, ref, f.arena.allocator(), .{});
    }

    /// Waits until the record of `ref` is in `state`, or gone for null.
    pub fn until(f: *Fixture, ref: scheduler.Ref, state: ?scheduler.State, seconds: i64) !?scheduler.Record {
        const give_up = nowMs() + seconds * 1000;
        while (true) {
            const r = try f.get(ref);
            if (if (r) |x| x.state == state else state == null) return r;
            if (nowMs() >= give_up) return error.Timeout;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
    }

    /// The rows of the history of the key, the newest first.
    pub fn rows(f: *Fixture, ref: scheduler.Ref) ![]const scheduler.Run {
        return (try f.client.history(io, .root, .{ .job = ref.job, .key = ref.key }, .{}, f.arena.allocator(), .{})).runs;
    }
};
