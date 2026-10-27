//! Three instances of a service on one mongod, without faults (13.4 of the
//! design): each with its own client and store and 4 slots, 2000 one-shot
//! jobs due at once and 5 jobs every second. The jobs note each run in the
//! collection `effects`: every one-shot job runs exactly once, and no two
//! runs of one repeating job overlap.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const fixture = @import("fixture.zig");

const Once = struct {
    effects: mongo.Collection,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-once" };

    pub fn run(self: *Once, ctx: *scheduler.Context) !void {
        try fixture.note(self.effects, ctx, fixture.nowMs(ctx.io()));
    }
};

const Every = struct {
    effects: mongo.Collection,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-every" };

    /// Long enough that a second run of the same job at the same time
    /// would show.
    pub fn run(self: *Every, ctx: *scheduler.Context) !void {
        const start = fixture.nowMs(ctx.io());
        try ctx.io().sleep(.fromMilliseconds(300), .awake);
        try fixture.note(self.effects, ctx, start);
    }
};

const Jobs = struct { once: *Once, every: *Every };

const one_shots = 2000;
const repeating = 5;
const instances = 3;

test "three instances run 2000 one-shot jobs once each and 5 recurring jobs without overlap" {
    try e2e.onZio(share);
}

fn share(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "instances");
    defer scene.close(io);
    var nodes: [instances]fixture.Node = undefined;
    var opened: usize = 0;
    defer for (nodes[0..opened]) |*n| n.close();
    for (&nodes) |*n| {
        try n.open(io, e2e.servers.plain, scene.database);
        opened += 1;
    }

    const client: scheduler.Client = .init(testing.allocator, io, nodes[0].store.store(), .{});
    var scheduling: Scheduling = .{ .client = &client };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..8) |part| try group.concurrent(io, Scheduling.part, .{ &scheduling, io, part });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), scheduling.failed.load(.acquire));
    for (0..repeating) |i| {
        var key: [4]u8 = undefined;
        _ = try client.schedule(io, e2e.within(io, .fromSeconds(10)), Every, .{ .key = try std.fmt.bufPrint(&key, "r{d}", .{i}), .when = .{ .repeat = .everySeconds(1) } }, .{});
    }

    var once: [instances]Once = undefined;
    var every: [instances]Every = undefined;
    var workers: [instances]scheduler.Worker(Jobs) = undefined;
    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.deinit(io);
    for (&workers, &once, &every, &nodes) |*w, *o, *e, *n| {
        o.* = .{ .effects = n.effects() };
        e.* = .{ .effects = n.effects() };
        w.* = try .init(testing.allocator, io, n.store.store(), .{ .once = o, .every = e }, fixture.options("instance", 4));
        made += 1;
    }
    for (&workers) |*w| try w.start(io);

    // The one-shot jobs end, and their records go; then each repeating job
    // runs a few times more.
    const jobs = scene.admin.collection(scene.database, "scheduler_jobs");
    var limit: fixture.Limit = .of(io, 120, "the one-shot jobs to end");
    while (try jobs.countDocuments(io, .of(e2e.within(io, .fromSeconds(10))), .{ .job = Once.scheduler_job.name }, .{ .allocator = testing.allocator }) > 0) try limit.tick(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    limit = .of(io, 60, "three runs of each repeating job");
    while (try fewestRuns(io, &scene) < 3) try limit.tick(io);
    for (&workers) |*w| try fixture.stop(io, w);

    // Each one-shot job once, and each instance ran some.
    const ones = try fixture.effectsOf(io, scene.effects(), arena, Once.scheduler_job.name);
    var keys: std.StringHashMapUnmanaged(u32) = .empty;
    var by_instance: std.StringHashMapUnmanaged(u32) = .empty;
    for (ones) |effect| {
        const seen = try keys.getOrPutValue(arena, effect.key, 0);
        seen.value_ptr.* += 1;
        if (seen.value_ptr.* == 2) std.debug.print("{s} ran more than once\n", .{effect.key});
        (try by_instance.getOrPutValue(arena, effect.instance, 0)).value_ptr.* += 1;
    }
    try testing.expectEqual(@as(usize, one_shots), ones.len);
    try testing.expectEqual(@as(u32, one_shots), keys.count());
    try testing.expectEqual(@as(u32, instances), by_instance.count());
    for (&workers) |*w| try testing.expectEqual(@as(u64, 0), w.stats().taken_over);

    // The runs of each repeating job, one after another.
    const runs = try fixture.effectsOf(io, scene.effects(), arena, Every.scheduler_job.name);
    for (runs, 0..) |run, i| {
        for (runs[0..i]) |before| {
            if (!std.mem.eql(u8, before.key, run.key)) continue;
            if (run.start < before.end) {
                std.debug.print("{s}: a run began at {d} before the run of {d} ended at {d}\n", .{ run.key, run.start, before.start, before.end });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Puts the one-shot jobs on now, in 8 parts, each from a task of its own.
const Scheduling = struct {
    client: *const scheduler.Client,
    failed: std.atomic.Value(u32) = .init(0),

    fn part(s: *Scheduling, io: Io, index: usize) void {
        const size = one_shots / 8;
        for (index * size..(index + 1) * size) |n| {
            var buffer: [8]u8 = undefined;
            var d: scheduler.Diagnostics = .{};
            const key = std.fmt.bufPrint(&buffer, "o{d:0>4}", .{n}) catch "";
            if (s.client.schedule(io, e2e.within(io, .fromSeconds(10)), Once, .{ .key = key, .when = .{ .after = .zero } }, .{ .diagnostics = &d })) |scheduled| {
                if (scheduled == .created) continue;
            } else |err| std.debug.print("schedule of {s}: {t}: {s}\n", .{ key, err, d.message() });
            _ = s.failed.fetchAdd(1, .acq_rel);
        }
    }
};

/// The runs of the repeating job that ran least.
fn fewestRuns(io: Io, scene: *fixture.Scene) !usize {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const runs = try fixture.effectsOf(io, scene.effects(), arena.allocator(), Every.scheduler_job.name);
    var fewest: usize = std.math.maxInt(usize);
    for (0..repeating) |i| {
        var key: [4]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "r{d}", .{i});
        var n: usize = 0;
        for (runs) |run| {
            if (std.mem.eql(u8, run.key, name)) n += 1;
        }
        fewest = @min(fewest, n);
    }
    return fewest;
}
