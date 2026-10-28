//! A killed instance (13.4 of the design): a worker in a process of its
//! own, programs/worker_child.zig, claims a job and notes the start of its
//! run; the test sends the process SIGKILL; once the lease of that claim
//! ends, the worker of the test takes the job over and runs it, as attempt
//! 2, and the history shows the killed attempt as abandoned. On Linux and
//! macOS: elsewhere the test is skipped, and `zig build check` still
//! builds the program.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const programs = @import("programs");
const e2e = @import("root.zig");
const fixture = @import("fixture.zig");

/// The job of programs/worker_child.zig; here a run ends at once.
const Kill = struct {
    effects: mongo.Collection,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-kill", .history = .forever };

    pub fn run(self: *Kill, ctx: *scheduler.Context) !void {
        try fixture.note(self.effects, ctx, fixture.nowMs(ctx.io()));
    }
};

test "a killed instance's job is taken over and its attempt is abandoned" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    try e2e.onZio(killed);
}

fn killed(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "kill");
    defer scene.close(io);
    var node: fixture.Node = undefined;
    try node.open(io, e2e.servers.plain, scene.database);
    defer node.close();
    const client: scheduler.Client = .init(testing.allocator, io, node.store.store(), .{});
    const ref: scheduler.Ref = .of(Kill, "k");
    _ = try client.schedule(io, e2e.within(io, .fromSeconds(10)), Kill, .{ .key = ref.key, .when = .{ .after = .zero } }, .{});

    // The child claims the job and holds its run.
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("SCHEDULER_E2E_URI", e2e.servers.plain);
    try environ.put("SCHEDULER_E2E_DATABASE", scene.database);
    var child = try std.process.spawn(io, .{ .argv = &.{programs.worker_child}, .environ_map = &environ, .stdout = .ignore });
    // Does nothing once the child was waited for.
    defer child.kill(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var limit: fixture.Limit = .of(io, 30, "the run in the child");
    const killed_run = while (true) {
        const runs = try fixture.effectsOf(io, scene.effects(), arena, Kill.scheduler_job.name);
        if (runs.len > 0) break runs[0];
        try limit.tick(io);
    };
    try std.posix.kill(child.id orelse return error.TestUnexpectedResult, .KILL);
    const term = try child.wait(io);
    if (term != .signal or term.signal != .KILL) {
        std.debug.print("the child ended so: {f}\n", .{term});
        return error.TestUnexpectedResult;
    }

    // Once the lease ends, the worker here takes the job over and runs it.
    var job: Kill = .{ .effects = node.effects() };
    var worker: scheduler.Worker(struct { kill: *Kill }) = try .init(testing.allocator, io, node.store.store(), .{ .kill = &job }, fixture.options("survivor", 1));
    defer worker.deinit(io);
    try worker.start(io);
    limit = .of(io, 30, "the job to be taken over and to succeed");
    while (try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{}) != null) try limit.tick(io);
    try fixture.stop(io, &worker);
    try testing.expectEqual(@as(u64, 1), worker.stats().taken_over);
    const runs = try fixture.effectsOf(io, scene.effects(), arena, Kill.scheduler_job.name);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqual(@as(i64, 2), runs[1].attempt);

    // The history: the killed attempt abandoned, and the one that followed.
    const rows = (try client.history(io, e2e.within(io, .fromSeconds(10)), .{ .job = ref.job, .key = ref.key }, .{}, arena, .{})).runs;
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| switch (row.fence) {
        1 => {
            try testing.expectEqual(scheduler.RunOutcome.abandoned, row.outcome);
            try testing.expectEqual(@as(u32, 1), row.attempt);
            try testing.expectEqualStrings(killed_run.instance, row.instance);
        },
        2 => {
            try testing.expectEqual(scheduler.RunOutcome.succeeded, row.outcome);
            try testing.expect(std.mem.startsWith(u8, row.instance, "survivor/"));
        },
        else => return error.TestUnexpectedResult,
    };
}
