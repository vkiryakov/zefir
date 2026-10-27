//! 200 jobs that repeat every second (13.5 of the design), for 60 s, run
//! as the storm's jobs are: by four instances of 16 slots, through a proxy
//! that cuts every connection every 2 s. A run takes 100 ms; every tenth
//! job takes 1.5 s, longer than its period and than `renew_every`, so its
//! owner renews the lease while it runs and the next run comes late.
//!
//! No two runs of a job overlap, whichever instances run them: the handler
//! notes, in memory, that a run of its job goes on, and counts a run that
//! begins while another one goes. And no job is left behind: a claim takes
//! the oldest due job first, so a slow machine delays every job of a kind
//! about alike, and each job runs at least a quarter as many times as the
//! median job of its kind, long or short. A long job runs about 40 times
//! here and a short one about 60; one that no instance takes, or that
//! something holds for much of the minute, falls below. The test prints
//! the slowest jobs, and the record of the slowest as it is at the end.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const e2e = @import("e2e");
const fixture = e2e.fixture;
const stress = @import("root.zig");

const job_count = 200;
const load_time: Io.Duration = .fromSeconds(60);
const short_run: Io.Duration = .fromMilliseconds(100);
const long_run: Io.Duration = .fromMilliseconds(1500);
/// A job runs at least 1 / `least_share` as many times as the median job
/// of its kind.
const least_share = 4;

const Every = struct {
    jobs: []Runs,
    /// Runs that began while another run of their job went on.
    overlaps: std.atomic.Value(u32) = .init(0),
    /// Runs that stood for runs of their schedule that were missed.
    late: std.atomic.Value(u32) = .init(0),

    pub const scheduler_job: scheduler.Job = .{ .name = "stress-every" };

    pub const Payload = struct { n: u32 };

    pub fn run(self: *Every, ctx: *scheduler.Context, payload: Payload) !void {
        if (payload.n >= self.jobs.len) return error.TestUnexpectedJob;
        const job = &self.jobs[payload.n];
        if (job.going.swap(true, .acq_rel)) _ = self.overlaps.fetchAdd(1, .acq_rel);
        defer job.going.store(false, .release);
        _ = job.runs.fetchAdd(1, .acq_rel);
        if (ctx.info().missed > 0) _ = self.late.fetchAdd(1, .acq_rel);
        try ctx.io().sleep(if (payload.n % 10 == 0) long_run else short_run, .awake);
    }
};

/// What the handler notes of one job.
const Runs = struct {
    going: std.atomic.Value(bool) = .init(false),
    runs: std.atomic.Value(u32) = .init(0),
};

const Jobs = struct { every: *Every };

test "200 recurring jobs every second for 60 s without overlap" {
    try stress.onZio(recurring);
}

fn recurring(io: Io) !void {
    var stage: stress.Stage = undefined;
    try stage.open(io, "recurring");
    defer stage.close(io);

    const jobs = try testing.allocator.alloc(Runs, job_count);
    defer testing.allocator.free(jobs);
    @memset(jobs, .{});
    var job: Every = .{ .jobs = jobs };

    const client: scheduler.Client = .init(testing.allocator, io, stage.direct.store.store(), .{});
    for (0..job_count) |n| {
        var buffer: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "e{d:0>3}", .{n});
        const scheduled = try client.schedule(io, e2e.within(io, .fromSeconds(10)), Every, .{ .key = key, .when = .{ .repeat = .everySeconds(1) }, .payload = .{ .n = @intCast(n) } }, .{});
        try testing.expectEqual(scheduler.Client.Scheduled.created, scheduled);
    }

    var workers: [stress.instances]scheduler.Worker(Jobs) = undefined;
    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.deinit(io);
    for (&workers, &stage.nodes) |*w, *n| {
        w.* = try .init(testing.allocator, io, n.store.store(), .{ .every = &job }, stress.options());
        made += 1;
    }
    for (&workers) |*w| try w.start(io);
    var cutter: stress.Cutter = .{ .proxy = &stage.proxy };
    try cutter.start(io);
    var cutting = true;
    defer if (cutting) cutter.stop(io);

    try io.sleep(load_time, .awake);
    cutting = false;
    cutter.stop(io);
    for (&workers) |*w| try fixture.stop(io, w);

    var total: u64 = 0;
    var counts: [job_count]u32 = undefined;
    for (jobs, &counts) |*j, *n| {
        n.* = j.runs.load(.acquire);
        total += n.*;
    }
    const sum = stress.statsOf(&workers);
    std.debug.print("    {d} runs in {d} s, {d} late; {d} overlapped; {d} rounds of cuts, {d} connections cut; coalesced {d}, taken over {d}, lost {d}, unreadable {d}, gave up {d}, store errors {d}\n", .{
        total, load_time.toSeconds(), job.late.load(.acquire), job.overlaps.load(.acquire), cutter.rounds.load(.acquire), cutter.cut.load(.acquire), sum.coalesced, sum.taken_over, sum.lost, sum.unreadable, sum.gave_up, sum.store_errors,
    });

    // The slowest jobs, and how far the slowest of each kind is from the
    // median of its kind.
    var order: [job_count]u8 = undefined;
    for (&order, 0..) |*i, n| i.* = @intCast(n);
    std.mem.sort(u8, &order, &counts, struct {
        fn less(c: *const [job_count]u32, a: u8, b: u8) bool {
            return c[a] < c[b] or (c[a] == c[b] and a < b);
        }
    }.less);
    std.debug.print("    the slowest:", .{});
    for (order[0..5]) |n| std.debug.print(" e{d:0>3} {d} times;", .{ n, counts[n] });
    std.debug.print("\n", .{});
    var behind: ?u8 = null;
    for ([_]bool{ true, false }) |long| {
        var kind: [job_count]u32 = undefined;
        var len: usize = 0;
        for (counts, 0..) |n, i| if ((i % 10 == 0) == long) {
            kind[len] = n;
            len += 1;
        };
        std.mem.sort(u32, kind[0..len], {}, std.sort.asc(u32));
        const median = kind[len / 2];
        std.debug.print("    {s} jobs: {d} to {d} times, the median {d}\n", .{ if (long) "long" else "short", kind[0], kind[len - 1], median });
        for (order) |n| if ((n % 10 == 0) == long) {
            if (counts[n] == 0 or counts[n] * least_share < median) behind = n;
            break;
        };
    }
    try testing.expectEqual(@as(u32, 0), job.overlaps.load(.acquire));
    if (behind) |n| {
        var key: [8]u8 = undefined;
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const r = (try client.get(io, e2e.within(io, .fromSeconds(10)), .of(Every, try std.fmt.bufPrint(&key, "e{d:0>3}", .{n})), arena_state.allocator(), .{})) orelse return error.TestUnexpectedResult;
        std.debug.print("    e{d:0>3} ran {d} times, less than a {d}th of the median of its kind: left behind; its record is {t}, attempt {d}, fence {d}, run_at {?f}, last {?t}, unreadable since {?f}\n", .{
            n, counts[n], least_share, r.state, r.attempt, r.fence, r.run_at, if (r.last) |last| last.outcome else null, r.unreadable_since,
        });
        return error.TestUnexpectedResult;
    }
}
