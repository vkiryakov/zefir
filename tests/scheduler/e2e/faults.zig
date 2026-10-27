//! Workers on mongod through faults (13.4 and 9.12 of the design): replies
//! lost after the server ran a write, commands that the server fails, or
//! runs without their write concern (`failCommand`), a server that stops
//! answering (mongo-stall, paused)
//! during runs and during polling, and a server restarted during polling
//! and runs (mongo-restart). No job runs without a claim, none is lost,
//! and the workers find the server again.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const e2e = @import("root.zig");
const fixture = @import("fixture.zig");
const Proxy = @import("Proxy.zig");

// Lost replies.

/// The job of the scenario with lost replies; what a run does depends on
/// its key. Its effects go straight to the server, past the proxy.
const Lossy = struct {
    effects: mongo.Collection,
    proxy: *Proxy,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-lossy", .when_done = .{ .succeeded = .forever } };

    pub fn run(self: *Lossy, ctx: *scheduler.Context) !void {
        const io = ctx.io();
        const start = fixture.nowMs(io);
        const key = ctx.info().key;
        if (std.mem.eql(u8, key, "renew")) {
            // The reply of the next renewal is lost; the run outlasts two.
            try self.proxy.settle(io, .fromMilliseconds(600));
            self.proxy.loseReply(1);
            try io.sleep(.fromMilliseconds(2500), .awake);
        } else if (std.mem.eql(u8, key, "taken") and ctx.info().attempt == 1) {
            // The owner is cut off: it can neither renew nor report.
            self.proxy.freeze();
            while (true) try io.sleep(.fromSeconds(1), .awake);
        }
        try fixture.note(self.effects, ctx, start);
        if (std.mem.eql(u8, key, "finish")) {
            // The reply of this run's transition is lost.
            try self.proxy.settle(io, .fromMilliseconds(600));
            self.proxy.loseReply(1);
        }
    }
};

const LossyJobs = struct { lossy: *Lossy };

test "lost replies of claim, create, update, renew and finish" {
    try e2e.onZio(lostReplies);
}

fn lostReplies(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "lost");
    defer scene.close(io);
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var uri: [96]u8 = undefined;
    // Through the proxy, and straight.
    var p: fixture.Node = undefined;
    try p.open(io, try proxy.uri(&uri, "appName=scheduler-e2e-lost"), scene.database);
    defer p.close();
    var d: fixture.Node = undefined;
    try d.open(io, e2e.servers.plain, scene.database);
    defer d.close();
    const through: scheduler.Client = .init(testing.allocator, io, p.store.store(), .{});
    const straight: scheduler.Client = .init(testing.allocator, io, d.store.store(), .{});
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lossy: Lossy = .{ .effects = d.effects(), .proxy = &proxy };

    // create: the key is created once, and the store knows it made it.
    try proxy.settle(io, .fromMilliseconds(600));
    proxy.loseReply(1);
    try testing.expectEqual(scheduler.Client.Scheduled.created, try through.schedule(io, within10s(io), Lossy, .{ .key = "created", .when = .{ .after = .fromSeconds(3600) } }, .{}));
    try testing.expectEqual(@as(u32, 1), proxy.lostReplies());
    const created = (try straight.get(io, within10s(io), .of(Lossy, "created"), arena, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.Client.Scheduled.existing, try straight.schedule(io, within10s(io), Lossy, .{ .key = "created", .when = .{ .after = .zero } }, .{}));
    try testing.expectEqual(@as(usize, 1), (try straight.list(io, within10s(io), .{ .job = Lossy.scheduler_job.name }, .{}, arena, .{})).records.len);

    // update: applied once.
    try proxy.settle(io, .fromMilliseconds(600));
    proxy.loseReply(1);
    try testing.expectEqual(scheduler.Client.Changed.changed, try through.reschedule(io, within10s(io), .of(Lossy, "created"), .{ .after = .fromSeconds(7200) }, .{}));
    try testing.expectEqual(@as(u32, 2), proxy.lostReplies());
    const moved = (try straight.get(io, within10s(io), .of(Lossy, "created"), arena, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(created.revision + 1, moved.revision);

    // claim: of three records, the reply of the second is lost; the store
    // finds it by its tag, and each runs once, in the first attempt.
    for ([_][]const u8{ "c1", "c2", "c3" }) |key|
        _ = try straight.schedule(io, within10s(io), Lossy, .{ .key = key, .when = .{ .after = .zero } }, .{});
    try proxy.settle(io, .fromMilliseconds(600));
    proxy.loseReply(2);
    {
        var w: scheduler.Worker(LossyJobs) = try .init(testing.allocator, io, p.store.store(), .{ .lossy = &lossy }, fixture.options("claims", 4));
        defer w.deinit(io);
        try w.start(io);
        var limit: fixture.Limit = .of(io, 30, "the runs of c1, c2 and c3");
        while (try countEffects(io, &scene) < 3) try limit.tick(io);
        try fixture.stop(io, &w);
        try testing.expectEqual(@as(u64, 0), w.stats().store_errors);
        try testing.expectEqual(@as(u64, 0), w.stats().taken_over);
    }
    try testing.expectEqual(@as(u32, 3), proxy.lostReplies());
    for (try fixture.effectsOf(io, scene.effects(), arena, Lossy.scheduler_job.name)) |effect|
        try testing.expectEqual(@as(i64, 1), effect.attempt);

    // renew and finish, by a worker of one slot, whose only writes are
    // then those of its run: the renewal goes once more, and the
    // transition is found applied by its tag.
    var w: scheduler.Worker(LossyJobs) = try .init(testing.allocator, io, p.store.store(), .{ .lossy = &lossy }, fixture.options("one-slot", 1));
    defer w.deinit(io);
    try w.start(io);
    for ([_][]const u8{ "renew", "finish" }, [_]u32{ 4, 5 }) |key, lost| {
        _ = try straight.schedule(io, within10s(io), Lossy, .{ .key = key, .when = .{ .after = .zero } }, .{});
        const done = try awaitState(io, &straight, arena, key, .succeeded);
        try testing.expectEqual(@as(u64, 1), done.fence);
        // The record may change before the proxy drops the reply; the read
        // after the loss goes on a connection of its own, and is over once
        // the proxy has been quiet a while.
        var limit: fixture.Limit = .of(io, 30, "the lost reply");
        while (proxy.lostReplies() < lost) try limit.tick(io);
        try proxy.settle(io, .fromMilliseconds(600));
        try testing.expectEqual(lost, proxy.lostReplies());
    }
    try testing.expectEqual(@as(u64, 0), w.stats().store_errors);
    try testing.expectEqual(@as(u64, 0), w.stats().lost);

    // finish of a claim taken over: cut off, the worker cancels its run,
    // another instance takes the job over; then the reply of the late
    // transition is lost, and the store finds it not applied.
    var taker: scheduler.Worker(LossyJobs) = try .init(testing.allocator, io, d.store.store(), .{ .lossy = &lossy }, fixture.options("taker", 1));
    defer taker.deinit(io);
    _ = try straight.schedule(io, within10s(io), Lossy, .{ .key = "taken", .when = .{ .after = .zero } }, .{});
    var limit: fixture.Limit = .of(io, 30, "the run of taken");
    while (!proxy.frozen.load(.acquire)) try limit.tick(io);
    try taker.start(io);
    const taken = try awaitState(io, &straight, arena, "taken", .succeeded);
    try testing.expectEqual(@as(u64, 2), taken.fence);
    try proxy.settle(io, .fromMilliseconds(600));
    proxy.loseReply(1);
    proxy.thaw();
    limit = .of(io, 30, "the lost reply of the late transition");
    while (proxy.lostReplies() < 6) try limit.tick(io);
    try fixture.stop(io, &w);
    try fixture.stop(io, &taker);
    const after = (try straight.get(io, within10s(io), .of(Lossy, "taken"), arena, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.succeeded, after.state);
    try testing.expectEqual(taken.fence, after.fence);
    try testing.expectEqual(taken.revision, after.revision);
    try testing.expectEqual(@as(u64, 1), w.stats().lost);
    try testing.expectEqual(@as(u64, 1), taker.stats().taken_over);

    // Each key that ran, once.
    const effects = try fixture.effectsOf(io, scene.effects(), arena, Lossy.scheduler_job.name);
    try testing.expectEqual(@as(usize, 6), effects.len);
    for (effects, 0..) |effect, i| {
        for (effects[0..i]) |before| try testing.expect(!std.mem.eql(u8, before.key, effect.key));
    }
}

/// The context of a call of the tests: 10 s.
fn within10s(io: Io) core.Context {
    return e2e.within(io, .fromSeconds(10));
}

/// The runs noted in `effects` so far.
fn countEffects(io: Io, scene: *fixture.Scene) !u64 {
    return scene.effects().countDocuments(io, .of(within10s(io)), .{}, .{ .allocator = testing.allocator });
}

/// The record of e2e-lossy `key`, once it is in `state`.
fn awaitState(io: Io, client: *const scheduler.Client, arena: std.mem.Allocator, key: []const u8, state: scheduler.State) !scheduler.Record {
    var limit: fixture.Limit = .of(io, 30, key);
    while (true) {
        if (try client.get(io, within10s(io), .of(Lossy, key), arena, .{})) |r| if (r.state == state) return r;
        try limit.tick(io);
    }
}

// failCommand.

/// The job of the scenario with failed commands: each run holds 500 ms, so
/// that a fail point set while the runs go meets their finishes.
const Failing = struct {
    effects: mongo.Collection,
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-failing", .history = .forever };

    pub fn run(self: *Failing, ctx: *scheduler.Context) !void {
        const start = fixture.nowMs(ctx.io());
        try self.probe.run(ctx, false);
        try ctx.io().sleep(.fromMilliseconds(500), .awake);
        try fixture.note(self.effects, ctx, start);
    }
};

test "failCommand closeConnection and 11600 on findAndModify and update" {
    try e2e.onZio(failedCommands);
}

fn failedCommands(io: Io) !void {
    const app = "scheduler-e2e-failpoint";
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "failpoint");
    defer scene.close(io);
    defer scene.admin.failPointOff(io);
    // The worker's client has the appName that the fail point names; the
    // effects and the client of the test go past it.
    var w_node: fixture.Node = undefined;
    try w_node.open(io, e2e.servers.plain ++ "/?appName=" ++ app, scene.database);
    defer w_node.close();
    var d: fixture.Node = undefined;
    try d.open(io, e2e.servers.plain, scene.database);
    defer d.close();
    const client: scheduler.Client = .init(testing.allocator, io, d.store.store(), .{});
    var probe: fixture.Probe = .{};
    var failing: Failing = .{ .effects = d.effects(), .probe = &probe };
    var w: scheduler.Worker(struct { failing: *Failing }) = try .init(testing.allocator, io, w_node.store.store(), .{ .failing = &failing }, fixture.options("failing", 4));
    defer w.deinit(io);

    const rounds = [_]struct { name: []const u8, close: bool }{ .{ .name = "closeConnection", .close = true }, .{ .name = "11600", .close = false } };
    for (rounds, 0..) |round, r| {
        for (0..8) |i| {
            var key: [8]u8 = undefined;
            _ = try client.schedule(io, within10s(io), Failing, .{ .key = try std.fmt.bufPrint(&key, "f{d}-{d}", .{ r, i }), .when = .{ .after = .zero } }, .{});
        }
        if (r == 0) try w.start(io);
        // Set while the runs go: their finishes write the rows of the
        // history (update) and the polls claim (findAndModify).
        var limit: fixture.Limit = .of(io, 30, "the runs of a round");
        while (probe.began.load(.acquire) < 8 * r + 1) try limit.tick(io);
        const errors = w.stats().store_errors;
        const filter = .{ "findAndModify", "update" };
        if (round.close)
            try scene.admin.failPoint(io, 3, .{ .failCommands = filter, .appName = app, .closeConnection = true })
        else
            try scene.admin.failPoint(io, 3, .{ .failCommands = filter, .appName = app, .errorCode = @as(i32, 11600) });
        limit = .of(io, 60, round.name);
        while (try scene.effects().countDocuments(io, .of(within10s(io)), .{}, .{ .allocator = testing.allocator }) < 8 * (r + 1)) try limit.tick(io);
        if (w.stats().store_errors <= errors) {
            std.debug.print("the fail point of {s} met no call of the worker\n", .{round.name});
            return error.TestUnexpectedResult;
        }
    }
    try fixture.stop(io, &w);
    scene.admin.failPointOff(io);

    // Every job ran once, by a claim of its own: its row of the history has
    // the fence and the instance of the run.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effects = try fixture.effectsOf(io, scene.effects(), arena, Failing.scheduler_job.name);
    try testing.expectEqual(@as(usize, 16), effects.len);
    const rows = (try client.history(io, within10s(io), .{ .job = Failing.scheduler_job.name }, .{ .limit = 1000 }, arena, .{})).runs;
    for (effects, 0..) |effect, i| {
        for (effects[0..i]) |before| try testing.expect(!std.mem.eql(u8, before.key, effect.key));
        const row = for (rows) |row| {
            if (std.mem.eql(u8, row.key, effect.key) and row.fence == effect.fence) break row;
        } else {
            std.debug.print("{s} ran with fence {d}, and no claim of that fence has a row\n", .{ effect.key, effect.fence });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(scheduler.RunOutcome.succeeded, row.outcome);
        try testing.expectEqualStrings(effect.instance, row.instance);
    }
    try testing.expectEqual(@as(usize, 0), (try client.list(io, within10s(io), .{ .job = Failing.scheduler_job.name }, .{}, arena, .{})).records.len);
}

// writeConcernError.

/// The job of the scenario whose writes run without their write concern:
/// each run outlasts two renewals of its lease.
const Unconfirmed = struct {
    effects: mongo.Collection,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-unconfirmed", .history = .forever };

    pub fn run(self: *Unconfirmed, ctx: *scheduler.Context) !void {
        const start = fixture.nowMs(ctx.io());
        try ctx.io().sleep(.fromMilliseconds(2500), .awake);
        try fixture.note(self.effects, ctx, start);
    }
};

test "failCommand writeConcernError on every write: each job runs once, and no call fails" {
    try e2e.onZio(unconfirmedWrites);
}

fn unconfirmedWrites(io: Io) !void {
    const app = "scheduler-e2e-concern";
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "concern");
    defer scene.close(io);
    defer scene.admin.failPointOff(io);
    // The client and the worker of the instance have the appName that the
    // fail point names; the effects and the reads of the test go past it.
    var node: fixture.Node = undefined;
    try node.open(io, e2e.servers.plain ++ "/?appName=" ++ app, scene.database);
    defer node.close();
    var d: fixture.Node = undefined;
    try d.open(io, e2e.servers.plain, scene.database);
    defer d.close();
    const client: scheduler.Client = .init(testing.allocator, io, node.store.store(), .{});
    const straight: scheduler.Client = .init(testing.allocator, io, d.store.store(), .{});
    var unconfirmed: Unconfirmed = .{ .effects = d.effects() };
    var w: scheduler.Worker(struct { unconfirmed: *Unconfirmed }) = try .init(testing.allocator, io, node.store.store(), .{ .unconfirmed = &unconfirmed }, fixture.options("concern", 4));
    defer w.deinit(io);

    // Every write of the instance runs, and its reply says that the journal
    // did not confirm it: the schedules, the claims, the renewals, the rows
    // of the history and the outcomes.
    try scene.admin.failPoint(io, 1000, .{
        .failCommands = .{ "findAndModify", "update", "delete" },
        .appName = app,
        .writeConcernError = .{ .code = @as(i32, 64), .codeName = "WriteConcernFailed", .errmsg = "e2e: the journal did not confirm the write in time" },
    });
    for (0..4) |i| {
        var key: [8]u8 = undefined;
        const scheduled = try client.schedule(io, within10s(io), Unconfirmed, .{ .key = try std.fmt.bufPrint(&key, "u{d}", .{i}), .when = .{ .after = .zero } }, .{});
        try testing.expectEqual(scheduler.Client.Scheduled.created, scheduled);
    }
    try w.start(io);
    var limit: fixture.Limit = .of(io, 60, "the runs of e2e-unconfirmed");
    while (try countEffects(io, &scene) < 4) try limit.tick(io);
    try fixture.stop(io, &w);
    // mongod counts the commands that the fail point met: at least a
    // schedule, a claim, a row and an outcome of each job.
    const off = try scene.admin.reply(io, "admin", .{ .configureFailPoint = "failCommand", .mode = "off" });
    defer off.deinit();
    const met = if (off.raw().get("count") catch null) |count| count.asI64() catch 0 else 0;
    if (met < 16) {
        std.debug.print("the fail point met {d} writes of the instance: {f}\n", .{ met, off.raw() });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u64, 0), w.stats().store_errors);
    try testing.expectEqual(@as(u64, 0), w.stats().lost);
    try testing.expectEqual(@as(u64, 4), w.stats().succeeded);

    // Each job ran once, in its first attempt, its row of the history has
    // the run, and its outcome removed its record.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effects = try fixture.effectsOf(io, scene.effects(), arena, Unconfirmed.scheduler_job.name);
    try testing.expectEqual(@as(usize, 4), effects.len);
    const rows = (try straight.history(io, within10s(io), .{ .job = Unconfirmed.scheduler_job.name }, .{ .limit = 100 }, arena, .{})).runs;
    try testing.expectEqual(@as(usize, 4), rows.len);
    for (effects, 0..) |effect, i| {
        for (effects[0..i]) |before| try testing.expect(!std.mem.eql(u8, before.key, effect.key));
        try testing.expectEqual(@as(i64, 1), effect.attempt);
        const row = for (rows) |row| {
            if (std.mem.eql(u8, row.key, effect.key)) break row;
        } else {
            std.debug.print("{s} ran, and has no row of the history\n", .{effect.key});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(scheduler.RunOutcome.succeeded, row.outcome);
        try testing.expectEqual(@as(u64, 1), row.fence);
    }
    try testing.expectEqual(@as(usize, 0), (try straight.list(io, within10s(io), .{ .job = Unconfirmed.scheduler_job.name }, .{}, arena, .{})).records.len);
}

// mongo-stall.

/// The job of the scenarios on mongo-stall. With `hold`, its first run
/// holds until the worker cancels it.
const Stalled = struct {
    probe: *fixture.Probe,
    hold: bool,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-stalled", .history = .forever };

    pub fn run(self: *Stalled, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, self.hold and self.probe.began.load(.acquire) == 0);
    }
};

const StalledJobs = struct { stalled: *Stalled };

/// mongo-stall, paused until `end` or the end of the test. It counts as
/// paused from before `docker pause` until `docker unpause` succeeded, so
/// that a pause that took effect and then failed, and an unpause that
/// failed, are undone at the end all the same.
const Pause = struct {
    on: bool = false,

    fn begin(p: *Pause, io: Io) !void {
        p.on = true;
        try e2e.pause(io, e2e.servers.stall_container);
    }

    fn end(p: *Pause, io: Io) !void {
        if (!p.on) return;
        try e2e.unpause(io, e2e.servers.stall_container);
        p.on = false;
    }

    /// For a `defer`: a failed test leaves the server running. A server
    /// that the failed pause left running makes `docker unpause` fail,
    /// which is printed and is no error.
    fn endAtLast(p: *Pause, io: Io) void {
        p.end(io) catch |err| std.debug.print("unpause of {s}: {t}\n", .{ e2e.servers.stall_container, err });
    }
};

test "mongo-stall paused during renewals" {
    try e2e.onZio(stallDuringRenewals);
}

fn stallDuringRenewals(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.stall, "stall_runs");
    defer scene.close(io);
    var node: fixture.Node = undefined;
    try node.open(io, e2e.servers.stall, scene.database);
    defer node.close();
    const client: scheduler.Client = .init(testing.allocator, io, node.store.store(), .{});
    var probe: fixture.Probe = .{};
    var stalled: Stalled = .{ .probe = &probe, .hold = true };
    var w: scheduler.Worker(StalledJobs) = try .init(testing.allocator, io, node.store.store(), .{ .stalled = &stalled }, fixture.options("stalled", 1));
    defer w.deinit(io);
    const ref: scheduler.Ref = .of(Stalled, "k");
    _ = try client.schedule(io, within10s(io), Stalled, .{ .key = ref.key, .when = .{ .after = .zero } }, .{});
    try w.start(io);
    var limit: fixture.Limit = .of(io, 30, "the run");
    while (probe.began.load(.acquire) < 1) try limit.tick(io);

    // The server answers nothing: the renewals fail, and the local deadline
    // of the lease cancels the run; nothing else runs meanwhile.
    var paused: Pause = .{};
    defer paused.endAtLast(io);
    try paused.begin(io);
    // The worker counts the run once its handler has ended.
    limit = .of(io, 30, "the cancel of the run");
    while (probe.cancelled.load(.acquire) < 1 or w.stats().lost < 1) try limit.tick(io);
    try testing.expectEqual(@as(u32, 1), probe.began.load(.acquire));
    try testing.expectEqual(@as(u64, 1), w.stats().lost);

    // Back: the job comes back, its attempt not counted, and runs again.
    try paused.end(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    limit = .of(io, 60, "the second run");
    while (try client.get(io, within10s(io), ref, arena, .{}) != null) try limit.tick(io);
    try fixture.stop(io, &w);
    try testing.expectEqual(@as(u32, 2), probe.began.load(.acquire));
    try testing.expectEqual(@as(u32, 1), probe.attempt.load(.acquire));
    const rows = (try client.history(io, within10s(io), .{ .job = ref.job, .key = ref.key }, .{}, arena, .{})).runs;
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| switch (row.fence) {
        1 => {
            try testing.expectEqual(scheduler.RunOutcome.interrupted, row.outcome);
            try testing.expectEqualDeep(@as(?[]const u8, "LeaseUnconfirmed"), row.error_name);
        },
        2 => try testing.expectEqual(scheduler.RunOutcome.succeeded, row.outcome),
        else => return error.TestUnexpectedResult,
    };
}

test "mongo-stall paused during polling" {
    try e2e.onZio(stallDuringPolling);
}

fn stallDuringPolling(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.stall, "stall_polls");
    defer scene.close(io);
    var node: fixture.Node = undefined;
    try node.open(io, e2e.servers.stall, scene.database);
    defer node.close();
    // Counts the polls.
    var counted: scheduler.testing.FaultyStore = .init(node.store.store());
    const client: scheduler.Client = .init(testing.allocator, io, node.store.store(), .{});
    var probe: fixture.Probe = .{};
    var stalled: Stalled = .{ .probe = &probe, .hold = false };
    const options = fixture.options("polling", 4);
    var w: scheduler.Worker(StalledJobs) = try .init(testing.allocator, io, counted.store(), .{ .stalled = &stalled }, options);
    defer w.deinit(io);
    try w.start(io);
    var limit: fixture.Limit = .of(io, 30, "the first polls");
    while (counted.calls(io, .claim) < 3) try limit.tick(io);
    // Due while the server is paused.
    const ref: scheduler.Ref = .of(Stalled, "k");
    _ = try client.schedule(io, within10s(io), Stalled, .{ .key = ref.key, .when = .{ .after = .fromSeconds(5) } }, .{});

    var paused: Pause = .{};
    defer paused.endAtLast(io);
    try paused.begin(io);
    limit = .of(io, 30, "the first failed poll");
    while (!w.stats().store_down) try limit.tick(io);
    // From then on the pauses between polls grow: poll_every × 2, × 4, × 8,
    // × 16, each less by up to a tenth, the calls themselves aside.
    var at = Io.Clock.awake.now(io);
    var polls = counted.calls(io, .claim);
    var pause: Io.Duration = options.poll_every;
    for (0..4) |_| {
        limit = .of(io, 30, "the next poll");
        while (counted.calls(io, .claim) == polls) {
            if (Io.Clock.awake.now(io).nanoseconds >= limit.end) return error.TestTimedOut;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        const now = Io.Clock.awake.now(io);
        pause = .fromNanoseconds(@min(pause.nanoseconds * 2, options.max_backoff.nanoseconds));
        const least = @divTrunc(pause.nanoseconds * 9, 10) - 30 * std.time.ns_per_ms;
        const gap = at.durationTo(now);
        if (gap.nanoseconds < least) {
            std.debug.print("a poll {d} ms after the one before; the pause is at least {d} ms\n", .{ gap.toMilliseconds(), @divTrunc(least, std.time.ns_per_ms) });
            return error.TestUnexpectedResult;
        }
        at = now;
        polls = counted.calls(io, .claim);
    }
    try testing.expect(w.stats().store_down);
    try testing.expectEqual(@as(u32, 0), probe.began.load(.acquire));

    // Back: the poll finds the server again, and the job runs once.
    try paused.end(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    limit = .of(io, 60, "the run after the pause");
    while (try client.get(io, within10s(io), ref, arena_state.allocator(), .{}) != null) try limit.tick(io);
    try fixture.stop(io, &w);
    try testing.expectEqual(@as(u32, 1), probe.began.load(.acquire));
    try testing.expect(!w.stats().store_down);
}

// mongo-restart.

/// A job whose first attempt holds until the worker cancels it; the
/// attempt that takes it over ends at once.
const Held = struct {
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-held", .history = .forever };

    pub fn run(self: *Held, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, ctx.info().attempt == 1);
    }
};

/// A job due while the server restarts.
const Later = struct {
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-later" };

    pub fn run(self: *Later, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, false);
    }
};

test "mongo-restart restarted during polling and runs" {
    try e2e.onZio(restartDuringRuns);
}

fn restartDuringRuns(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.restart, "restart");
    defer scene.close(io);
    var a: fixture.Node = undefined;
    try a.open(io, e2e.servers.restart, scene.database);
    defer a.close();
    const client: scheduler.Client = .init(testing.allocator, io, a.store.store(), .{});
    for ([_][]const u8{ "h1", "h2" }) |key| _ = try client.schedule(io, within10s(io), Held, .{ .key = key, .when = .{ .after = .zero } }, .{});
    for ([_][]const u8{ "l1", "l2", "l3" }) |key| _ = try client.schedule(io, within10s(io), Later, .{ .key = key, .when = .{ .after = .fromSeconds(4) } }, .{});
    var at_a: fixture.Probe = .{};
    var held_a: Held = .{ .probe = &at_a };
    // A slot more than the runs take: the worker polls while they go.
    var wa: scheduler.Worker(struct { held: *Held }) = try .init(testing.allocator, io, a.store.store(), .{ .held = &held_a }, fixture.options("before", 3));
    defer wa.deinit(io);
    try wa.start(io);
    var limit: fixture.Limit = .of(io, 30, "the runs before the restart");
    while (at_a.began.load(.acquire) < 2) try limit.tick(io);

    // What mongod keeps in its journal: the records as they are now.
    // mongo-restart keeps its data in memory, so the test puts them back
    // after the restart, as a server that keeps its data on disk would
    // find them.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const jobs = scene.admin.collection(scene.database, "scheduler_jobs");
    var kept: std.ArrayList(bson.RawDocument) = .empty;
    {
        const op: mongo.OperationContext = .of(within10s(io));
        var cursor = try jobs.find(io, op, .{}, .{ .allocator = arena });
        defer cursor.deinit(io);
        while (try cursor.next(io, op)) |doc| try kept.append(arena, (try doc.dupe(arena)).raw());
    }
    try testing.expectEqual(@as(usize, 5), kept.items.len);

    // The restart cuts the worker off during its runs and its polls: the
    // polls fail, and the runs end, by the local deadline of their lease
    // while the server is away, or as removed if it came back without them
    // first; then the worker finds the server again.
    try e2e.restart(io, e2e.servers.restart_container);
    try scene.admin.awaitAnswer(io);
    limit = .of(io, 30, "the cancels of the runs");
    while (at_a.cancelled.load(.acquire) < 2) try limit.tick(io);
    limit = .of(io, 30, "the worker to find the server again");
    while (wa.stats().store_down or wa.stats().store_errors == 0) try limit.tick(io);
    try fixture.stop(io, &wa);
    _ = try jobs.insertMany(io, .of(within10s(io)), kept.items, .{ .allocator = arena });

    // Another worker, started on the records as they were: the leases of
    // the runs ended meanwhile, and it takes them over; the jobs due while
    // the server was away run once each.
    var b: fixture.Node = undefined;
    try b.open(io, e2e.servers.restart, scene.database);
    defer b.close();
    var at_b: fixture.Probe = .{};
    var later: fixture.Probe = .{};
    var held_b: Held = .{ .probe = &at_b };
    var later_b: Later = .{ .probe = &later };
    var wb: scheduler.Worker(struct { held: *Held, later: *Later }) = try .init(testing.allocator, io, b.store.store(), .{ .held = &held_b, .later = &later_b }, fixture.options("after", 4));
    defer wb.deinit(io);
    try wb.start(io);
    limit = .of(io, 60, "the jobs after the restart");
    while (try jobs.countDocuments(io, .of(within10s(io)), .{}, .{ .allocator = testing.allocator }) > 0) try limit.tick(io);
    try fixture.stop(io, &wb);
    try testing.expectEqual(@as(u64, 2), wb.stats().taken_over);
    try testing.expectEqual(@as(u32, 2), at_b.began.load(.acquire));
    try testing.expectEqual(@as(u32, 2), at_b.attempt.load(.acquire));
    try testing.expectEqual(@as(u32, 3), later.began.load(.acquire));
    for ([_][]const u8{ "h1", "h2" }) |key| {
        const rows = (try client.history(io, within10s(io), .{ .job = Held.scheduler_job.name, .key = key }, .{}, arena, .{})).runs;
        try testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |row| switch (row.fence) {
            // The worker before the restart reported once the server was
            // back, or the one after it wrote the row of the attempt.
            1 => if (row.outcome != .abandoned) {
                try testing.expectEqual(scheduler.RunOutcome.interrupted, row.outcome);
                const why = row.error_name orelse "";
                if (!std.mem.eql(u8, why, "LeaseUnconfirmed") and !std.mem.eql(u8, why, "Cancelled")) {
                    std.debug.print("{s}: the run before the restart was interrupted with {s}\n", .{ key, why });
                    return error.TestUnexpectedResult;
                }
            },
            2 => try testing.expectEqual(scheduler.RunOutcome.succeeded, row.outcome),
            else => return error.TestUnexpectedResult,
        };
    }
}
