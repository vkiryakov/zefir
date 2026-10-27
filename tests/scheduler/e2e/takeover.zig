//! A frozen owner and a takeover (13.4 of the design). Worker A reaches
//! mongod through the proxy, worker B straight. A claims a job and runs
//! it; then the proxy freezes, and A can neither renew its lease nor
//! report: it cancels the run by its local deadline, before the lease ends
//! on the server, and B claims the job once it has, as attempt 2, taking it
//! over from A. When the proxy thaws, A reports, too late: its row of the
//! history replaces the row `abandoned` that B wrote for it, and the
//! record stays as B left it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const e2e = @import("root.zig");
const fixture = @import("fixture.zig");
const Proxy = @import("Proxy.zig");

const Hold = struct {
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-hold", .history = .forever, .when_done = .{ .succeeded = .forever } };

    /// The first attempt holds until the worker cancels it; a later one
    /// ends at once.
    pub fn run(self: *Hold, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, ctx.info().attempt == 1);
    }
};

const Jobs = struct { hold: *Hold };

test "a frozen owner cancels by its local deadline and another instance takes over" {
    try e2e.onZio(takeOver);
}

fn takeOver(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "takeover");
    defer scene.close(io);
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var uri: [96]u8 = undefined;
    var a: fixture.Node = undefined;
    try a.open(io, try proxy.uri(&uri, "appName=scheduler-e2e-frozen"), scene.database);
    defer a.close();
    var b: fixture.Node = undefined;
    try b.open(io, e2e.servers.plain, scene.database);
    defer b.close();
    var at_a: fixture.Probe = .{};
    var at_b: fixture.Probe = .{};
    var hold_a: Hold = .{ .probe = &at_a };
    var hold_b: Hold = .{ .probe = &at_b };
    var wa: scheduler.Worker(Jobs) = try .init(testing.allocator, io, a.store.store(), .{ .hold = &hold_a }, fixture.options("frozen", 1));
    defer wa.deinit(io);
    var wb: scheduler.Worker(Jobs) = try .init(testing.allocator, io, b.store.store(), .{ .hold = &hold_b }, fixture.options("taker", 1));
    defer wb.deinit(io);
    const client: scheduler.Client = .init(testing.allocator, io, b.store.store(), .{});
    const ref: scheduler.Ref = .of(Hold, "k");
    _ = try client.schedule(io, e2e.within(io, .fromSeconds(10)), Hold, .{ .key = ref.key, .when = .{ .after = .zero } }, .{});

    try wa.start(io);
    var limit: fixture.Limit = .of(io, 30, "the run of A");
    while (at_a.began.load(.acquire) < 1) try limit.tick(io);
    proxy.freeze();
    try wb.start(io);
    limit = .of(io, 30, "the cancel of the run of A and the run of B");
    while (at_a.ended.load(.acquire) < 1 or at_b.ended.load(.acquire) < 1) try limit.tick(io);
    // A stopped before B began, by the local deadline of its lease.
    try testing.expectEqual(@as(u32, 1), at_a.cancelled.load(.acquire));
    try testing.expectEqual(@as(u32, 1), at_b.began.load(.acquire));
    try testing.expectEqual(@as(u32, 2), at_b.attempt.load(.acquire));
    if (at_a.ended_ms.load(.acquire) > at_b.began_ms.load(.acquire)) {
        std.debug.print("A ended its run at {d}, after B began it at {d}\n", .{ at_a.ended_ms.load(.acquire), at_b.began_ms.load(.acquire) });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u64, 1), wa.stats().lost);
    try testing.expectEqual(@as(u64, 1), wb.stats().taken_over);

    // B's outcome is the record's; B wrote the row of A's attempt as
    // abandoned, since A has not reported.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    limit = .of(io, 30, "the record to succeed");
    const done = while (true) {
        if (try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{})) |r| if (r.state == .succeeded) break r;
        try limit.tick(io);
    };
    try testing.expectEqual(@as(u64, 2), done.fence);
    try testing.expectEqual(@as(u32, 2), done.attempt);
    try expectRow(io, &client, arena, 1, .abandoned, null, "frozen/");
    try expectRow(io, &client, arena, 2, .succeeded, null, "taker/");

    // Thawed, A reports: its row replaces the abandoned one, and its
    // transition is refused.
    proxy.thaw();
    try fixture.stop(io, &wa);
    const after = (try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.succeeded, after.state);
    try testing.expectEqual(done.fence, after.fence);
    try testing.expectEqual(done.revision, after.revision);
    try expectRow(io, &client, arena, 1, .interrupted, "LeaseUnconfirmed", "frozen/");
    try fixture.stop(io, &wb);
}

/// The row of the claim `fence` of the job "k" has this outcome, error and
/// instance.
fn expectRow(io: Io, client: *const scheduler.Client, arena: std.mem.Allocator, fence: u64, outcome: scheduler.RunOutcome, error_name: ?[]const u8, instance: []const u8) !void {
    const rows = (try client.history(io, e2e.within(io, .fromSeconds(10)), .{ .job = Hold.scheduler_job.name, .key = "k" }, .{}, arena, .{})).runs;
    for (rows) |row| {
        if (row.fence != fence) continue;
        testing.expectEqual(outcome, row.outcome) catch |err| {
            std.debug.print("the row of claim {d}: {t} {?s} of {s}\n", .{ fence, row.outcome, row.error_name, row.instance });
            return err;
        };
        try testing.expectEqualDeep(error_name, row.error_name);
        try testing.expect(std.mem.startsWith(u8, row.instance, instance));
        try testing.expectEqual(fence, @as(u64, row.attempt));
        return;
    }
    std.debug.print("no row of claim {d} among {d}\n", .{ fence, rows.len });
    return error.TestUnexpectedResult;
}
