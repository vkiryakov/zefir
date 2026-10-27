//! A storm of one-shot jobs (13.5 of the design): 20,000 jobs due at one
//! moment, four instances of a service with 16 slots each, each with its
//! own client and store, as a process of its own would have, and a proxy
//! between them and mongo-plain that cuts every connection every 2 s. The
//! jobs go on their time past the proxy, before the workers start.
//!
//! The handler of the job only counts the runs of each, in memory. Every
//! job runs at least once, and none is lost: no record is left at the end,
//! as a one-shot job that succeeded goes. A job may run twice when a cut
//! takes the reply of its outcome and its lease ends before the owner gets
//! it through: the test prints how many did, and fails when more did than
//! the cuts can explain, the runs in flight at each.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const e2e = @import("e2e");
const fixture = e2e.fixture;
const stress = @import("root.zig");

const job_count = 20_000;
/// The tasks that put the jobs on their time, each a part of them.
const parts = 32;

const Storm = struct {
    /// The runs of each job, by its number.
    runs: []std.atomic.Value(u32),
    /// The jobs that ran at least once.
    ran: std.atomic.Value(u32) = .init(0),

    pub const scheduler_job: scheduler.Job = .{ .name = "stress-storm" };

    pub const Payload = struct { n: u32 };

    pub fn run(self: *Storm, _: *scheduler.Context, payload: Payload) !void {
        if (payload.n >= self.runs.len) return error.TestUnexpectedJob;
        if (self.runs[payload.n].fetchAdd(1, .acq_rel) == 0) _ = self.ran.fetchAdd(1, .acq_rel);
    }
};

const Jobs = struct { storm: *Storm };

test "20 000 one-shot jobs at one moment with 4 workers of 16 slots and a proxy cutting connections every 2 s" {
    try stress.onZio(storm);
}

fn storm(io: Io) !void {
    var stage: stress.Stage = undefined;
    try stage.open(io, "storm");
    defer stage.close(io);

    const runs = try testing.allocator.alloc(std.atomic.Value(u32), job_count);
    defer testing.allocator.free(runs);
    @memset(runs, .init(0));
    var job: Storm = .{ .runs = runs };

    // All at one moment, the store's now: due once they are there.
    const client: scheduler.Client = .init(testing.allocator, io, stage.direct.store.store(), .{});
    var scheduling: Scheduling = .{ .client = &client, .at = stage.direct.store.now(io) };
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (0..parts) |part| try group.concurrent(io, Scheduling.part, .{ &scheduling, io, part });
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), scheduling.failed.load(.acquire));

    var workers: [stress.instances]scheduler.Worker(Jobs) = undefined;
    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.deinit(io);
    for (&workers, &stage.nodes) |*w, *n| {
        w.* = try .init(testing.allocator, io, n.store.store(), .{ .storm = &job }, stress.options());
        made += 1;
    }
    const began = Io.Clock.awake.now(io);
    for (&workers) |*w| try w.start(io);
    var cutter: stress.Cutter = .{ .proxy = &stage.proxy };
    try cutter.start(io);
    var cutting = true;
    defer if (cutting) cutter.stop(io);

    var limit: fixture.Limit = .of(io, 240, "every job to run");
    while (job.ran.load(.acquire) < job_count) try limit.tick(io);
    const took = began.durationTo(Io.Clock.awake.now(io));
    // Every record finished and went.
    try expectNoneLeft(io, &stage, &client);
    cutting = false;
    cutter.stop(io);
    for (&workers) |*w| try fixture.stop(io, w);

    var total: u64 = 0;
    var twice: u32 = 0;
    for (runs) |*r| {
        const n = r.load(.acquire);
        total += n;
        if (n > 1) twice += 1;
    }
    const rounds = cutter.rounds.load(.acquire);
    const sum = stress.statsOf(&workers);
    std.debug.print("    {d} jobs ran in {d} ms, in {d} runs: {d} ran more than once; {d} rounds of cuts, {d} connections cut; claimed {d}, taken over {d}, lost {d}, store errors {d}\n", .{
        job_count, took.toMilliseconds(), total, twice, rounds, cutter.cut.load(.acquire), sum.claimed, sum.taken_over, sum.lost, sum.store_errors,
    });
    // A cut can make each run in flight at that moment come twice, no
    // more: those of the four instances' 16 slots.
    const most = @as(u64, rounds + 1) * stress.instances * stress.slots;
    if (total - job_count > most) {
        std.debug.print("    {d} runs more than the jobs; at most {d} for {d} rounds of cuts\n", .{ total - job_count, most, rounds });
        return error.TestUnexpectedResult;
    }
}

/// Puts the jobs on `at`, in `parts` parts, each from a task of its own.
const Scheduling = struct {
    client: *const scheduler.Client,
    at: scheduler.Instant,
    failed: std.atomic.Value(u32) = .init(0),

    fn part(s: *Scheduling, io: Io, index: usize) void {
        const size = job_count / parts;
        for (index * size..(index + 1) * size) |n| {
            var buffer: [8]u8 = undefined;
            var d: scheduler.Diagnostics = .{};
            const key = std.fmt.bufPrint(&buffer, "j{d:0>5}", .{n}) catch "";
            if (s.client.schedule(io, e2e.within(io, .fromSeconds(30)), Storm, .{ .key = key, .when = .{ .at = s.at }, .payload = .{ .n = @intCast(n) } }, .{ .diagnostics = &d })) |scheduled| {
                if (scheduled == .created) continue;
            } else |err| if (s.failed.load(.acquire) == 0) std.debug.print("schedule of {s}: {t}: {s}\n", .{ key, err, d.message() });
            _ = s.failed.fetchAdd(1, .acq_rel);
        }
    }
};

/// Waits until no record of the storm is left, for 60 s at most; shows
/// some of those left when it gives up.
fn expectNoneLeft(io: Io, stage: *stress.Stage, client: *const scheduler.Client) !void {
    const records = stage.scene.admin.collection(stage.scene.database, "scheduler_jobs");
    const began = Io.Clock.awake.now(io);
    while (try records.countDocuments(io, .of(e2e.within(io, .fromSeconds(10))), .{}, .{ .allocator = testing.allocator }) > 0) {
        if (began.durationTo(Io.Clock.awake.now(io)).toSeconds() < 60) {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        }
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const left = try client.list(io, e2e.within(io, .fromSeconds(10)), .{}, .{ .limit = 10 }, arena.allocator(), .{});
        for (left.records) |r| std.debug.print("    left: {s} {t}, attempt {d}, fence {d}\n", .{ r.key, r.state, r.attempt, r.fence });
        return error.TestRecordsLeft;
    }
}
