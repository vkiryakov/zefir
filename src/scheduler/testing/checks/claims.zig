//! The checks of claims and leases in `scheduler.testing.conformance`:
//! what a claim takes and in what order, what it never takes, a race of
//! claims, takeovers of expired leases, renewals, `next_in`, the store's
//! `now`, a claim of a removed record, and declared records.

const std = @import("std");
const Io = std.Io;
const Store = @import("../../Store.zig");
const Instant = @import("../../Instant.zig");
const model = @import("../../record.zig");
const Runner = @import("runner.zig");
const Error = Runner.Error;
const Record = model.Record;

pub fn s6(r: *Runner) Error!void {
    // Due records of two listed jobs at times 10 s apart, the oldest of all
    // of a job not listed, and one due in an hour.
    const due = [_]struct { job: []const u8, key: []const u8 }{
        .{ .job = "s6-a", .key = "k1" }, .{ .job = "s6-b", .key = "k2" }, .{ .job = "s6-a", .key = "k3" }, .{ .job = "s6-b", .key = "k4" }, .{ .job = "s6-a", .key = "k5" },
    };
    const base = r.now();
    var before: [due.len]Record = undefined;
    for (due, &before, 0..) |d, *b, i| {
        _ = try r.create(d.job, d.key, .{ .at = base.add(.fromSeconds(-50 + 10 * @as(i64, @intCast(i)))) });
        b.* = try r.fetch(d.job, d.key);
    }
    _ = try r.create("s6-c", "k0", .{ .at = base.add(.fromSeconds(-60)) });
    _ = try r.create("s6-a", "k6", .{ .after = .fromSeconds(3600) });

    const lease = r.ms(60_000);
    const first = try r.claim("s6-w1", &.{}, &.{ "s6-a", "s6-b" }, 3, lease);
    const second = try r.claim("s6-w2", &.{"s6-a"}, &.{"s6-b"}, 10, lease);
    try r.expect(first.claimed.len == 3 and second.claimed.len == 2, "claims of at most 3, then 10, of 5 due records took {d}, then {d}", .{ first.claimed.len, second.claimed.len });
    var taken: [due.len]Store.Claimed = undefined;
    @memcpy(taken[0..3], first.claimed);
    @memcpy(taken[3..], second.claimed);
    for (taken, before) |c, b| {
        const rec = c.record;
        try r.expect(std.mem.eql(u8, rec.key, b.key), "a claim took {s}/{s} where {s}/{s}, older, was due", .{ rec.job, rec.key, b.job, b.key });
        try r.expect(c.took_over == null, "a claim of a pending record gave a took_over", .{});
        try r.expect(rec.attempt == b.attempt +% 1 and rec.fence == b.fence +% 1, "a claim gave attempt {d} and fence {d}, not {d} and {d}", .{ rec.attempt, rec.fence, b.attempt +% 1, b.fence +% 1 });
        try r.expect(rec.claimed_at.?.unix_ms >= b.run_at.?.unix_ms, "a claim at {f} took a record due at {?f}", .{ rec.claimed_at.?, b.run_at });
        try r.expectNear(rec.lease_until, rec.claimed_at.?, rec.claimed_at.?, lease, "lease_until of a claim");
        try r.expectSame(b, rec, &.{ "state", "run_at", "attempt", "fence", "owner", "claimed_at", "lease_until" }, "a claim");
    }
    const none = try r.claim("s6-w3", &.{"s6-a"}, &.{"s6-b"}, 10, lease);
    try r.expect(none.claimed.len == 0, "a claim took a record of a job not listed, or not due yet", .{});
    const other = try r.claim("s6-w3", &.{"s6-c"}, &.{}, 10, lease);
    try r.expect(other.claimed.len == 1 and std.mem.eql(u8, other.claimed[0].record.job, "s6-c"), "a claim of the job s6-c took {d} records", .{other.claimed.len});
}

pub fn s7(r: *Runner) Error!void {
    const job = "s7-send";
    const past: Store.Moment = .{ .at = r.now().add(.fromSeconds(-60)) };
    const lease = r.ms(60_000);
    // Paused by the client and by a finish, both due long ago.
    _ = try r.create(job, "paused", past);
    _ = try r.updated(try r.fetch(job, "paused"), .{ .state = .paused });
    const parked = try r.running(job, "parked", "s7-w1", lease);
    try r.finished(r.finishOf(parked, "s7-w1", .{ .wait = .{ .state = .paused, .run_at = past, .scheduled_at = null, .attempt = 0 } }));
    // Finished, succeeded and failed.
    for ([_]model.State{ .succeeded, .failed }, [_][]const u8{ "succeeded", "failed" }) |state, key| {
        const run = try r.running(job, key, "s7-w1", lease);
        try r.finished(r.finishOf(run, "s7-w1", .{ .done = .{ .state = state, .keep = .forever } }));
    }
    // Running with a live lease, and due in an hour.
    _ = try r.running(job, "leased", "s7-w1", lease);
    _ = try r.create(job, "future", .{ .after = .fromSeconds(3600) });

    const states = [_]model.State{ .paused, .paused, .succeeded, .failed, .running, .pending };
    const keys = [_][]const u8{ "paused", "parked", "succeeded", "failed", "leased", "future" };
    var kept: [keys.len]Record = undefined;
    for (keys, states, &kept) |key, state, *k| {
        k.* = try r.fetch(job, key);
        try r.expect(k.state == state, "{s}/{s} is {t}, not {t}", .{ job, key, k.state, state });
    }
    for (0..3) |_| {
        const result = try r.claim("s7-w2", &.{job}, &.{}, 10, lease);
        if (result.claimed.len > 0) return r.fail("a claim took {s}/{s}", .{ job, result.claimed[0].record.key });
    }
    for (keys, kept) |key, k| try r.expectSame(k, try r.fetch(job, key), &.{}, "a claim that took nothing");
}

/// The tasks of S8: they claim records of one job, all at once, until none
/// is left.
const Race = struct {
    r: *Runner,
    /// The seed of the tags of each task.
    seeds: [8]u64,
    gate: Io.Event = .unset,
    stop: std.atomic.Value(bool) = .init(false),
    /// How many times each record was claimed, and by which task.
    claims: [200]std.atomic.Value(u32) = @splat(.init(0)),
    owners: [200]std.atomic.Value(u8) = @splat(.init(0)),
    /// The error of each task, if any.
    errors: [8]?anyerror = @splat(null),

    fn run(race: *Race, task: u8) void {
        race.gate.wait(race.r.io) catch return;
        race.claimAll(task) catch |err| {
            race.errors[task] = err;
        };
    }

    fn claimAll(race: *Race, task: u8) !void {
        var arena: std.heap.ArenaAllocator = .init(race.r.gpa);
        defer arena.deinit();
        const owner = [_]u8{ 's', '8', '-', 'w', '0' + task };
        // A tag of its own for each claim: a store that tells its claims by
        // tag after a lost reply would take one of the task for another.
        var tags: std.Random.DefaultPrng = .init(race.seeds[task]);
        while (!race.stop.load(.acquire)) {
            _ = arena.reset(.retain_capacity);
            var tag: Store.Tag = undefined;
            tags.random().bytes(&tag);
            const request: Store.ClaimRequest = .{ .owner = &owner, .any_key = &.{}, .keyed_only = &.{"s8-race"}, .max = 1 + task % 4, .lease = race.r.ms(60_000), .tag = tag };
            const result = try race.r.store().claim(race.r.io, race.r.ctx(), &request, .{ .allocator = arena.allocator() });
            if (result.claimed.len == 0) return;
            for (result.claimed) |c| {
                const i = std.fmt.parseInt(usize, c.record.key, 10) catch return error.KeyOfNoRecord;
                if (i >= race.claims.len) return error.KeyOfNoRecord;
                _ = race.claims[i].fetchAdd(1, .monotonic);
                race.owners[i].store(task, .monotonic);
            }
        }
    }
};

pub fn s8(r: *Runner) Error!void {
    for (0..200) |i| {
        var key: [3]u8 = undefined;
        _ = try r.create("s8-race", std.fmt.bufPrint(&key, "{d:0>3}", .{i}) catch unreachable, .{ .after = .zero });
    }
    var race: Race = .{ .r = r, .seeds = undefined };
    for (&race.seeds) |*seed| seed.* = r.rng.random().int(u64);
    {
        var group: Io.Group = .init;
        defer group.cancel(r.io);
        // On any way out, no task waits at the gate or claims on.
        defer race.gate.set(r.io);
        defer race.stop.store(true, .release);
        for (0..8) |task| group.concurrent(r.io, Race.run, .{ &race, @as(u8, @intCast(task)) }) catch return r.fail("no task for each of 8 claimers: io.concurrent failed", .{});
        race.gate.set(r.io);
        group.await(r.io) catch return r.fail("the check's task was canceled while 8 tasks claimed", .{});
    }
    for (race.errors, 0..) |failure, task| {
        if (failure) |err| return r.fail("task {d} of the race: a claim returned error.{t}", .{ task, err });
    }
    for (&race.claims, &race.owners, 0..) |*claims, *owner, i| {
        try r.expect(claims.load(.monotonic) == 1, "record {d} of 200 was claimed {d} times", .{ i, claims.load(.monotonic) });
        var key: [3]u8 = undefined;
        const rec = try r.fetch("s8-race", std.fmt.bufPrint(&key, "{d:0>3}", .{i}) catch unreachable);
        const expected = [_]u8{ 's', '8', '-', 'w', '0' + owner.load(.monotonic) };
        try r.expect(rec.state == .running and std.mem.eql(u8, rec.owner orelse "", &expected) and rec.attempt == 1 and rec.fence == 1, "record {d} after the race is {t} of {?s}, attempt {d}, fence {d}", .{ i, rec.state, rec.owner, rec.attempt, rec.fence });
    }
}

pub fn s9(r: *Runner) Error!void {
    const job = "s9-send";
    const lease = r.ms(1000);
    const first = try r.running(job, "k1", "s9-w1", lease);
    // Taken over by another owner once the lease expired, then by the first
    // owner again: attempt and fence grow, took_over names the owner before.
    const second = try r.takeOver("s9-w2", first, lease);
    const third = try r.takeOver("s9-w1", second.record, lease);
    for ([_]Store.Claimed{ second, third }, [_]Record{ first, second.record }) |took, held| {
        const rec = took.record;
        const over = took.took_over orelse return r.fail("a claim of an expired lease gave no took_over", .{});
        try r.expect(std.mem.eql(u8, over.owner, held.owner.?) and over.claimed_at.unix_ms == held.claimed_at.?.unix_ms, "took_over names {s} claimed at {f}, not {s} claimed at {f}", .{ over.owner, over.claimed_at, held.owner.?, held.claimed_at.? });
        try r.expect(rec.attempt == held.attempt +% 1 and rec.fence == held.fence +% 1, "a takeover gave attempt {d} and fence {d}, not {d} and {d}", .{ rec.attempt, rec.fence, held.attempt +% 1, held.fence +% 1 });
        try r.expect(rec.claimed_at.?.unix_ms >= held.lease_until.?.unix_ms, "a takeover at {f} of a lease until {f}", .{ rec.claimed_at.?, held.lease_until.? });
        try r.expectSame(held, rec, &.{ "attempt", "fence", "owner", "claimed_at", "lease_until" }, "a takeover");
    }
}

pub fn s10(r: *Runner) Error!void {
    const job = "s10-send";
    // The owner renews: lease_until from the store's now, nothing else.
    const held = try r.running(job, "k1", "s10-w1", r.ms(60_000));
    const t0 = r.now();
    const renewed = try r.renew(held, "s10-w1", .fromSeconds(7200));
    const t1 = r.now();
    try r.expect(renewed == .renewed, "renew by the owner answered {t}, not renewed", .{renewed});
    const longer = try r.fetch(job, "k1");
    try r.expectNear(longer.lease_until, t0, t1, .fromSeconds(7200), "lease_until of a renew of 2 h");
    try r.expectSame(held, longer, &.{"lease_until"}, "a renew");
    // Another owner or fence: lost, and nothing changes.
    var stranger = held;
    stranger.fence +%= 1;
    for ([_][]const u8{ "s10-w2", "s10-w1" }, [_]Record{ held, stranger }) |owner, other| {
        const result = try r.renew(other, owner, r.ms(60_000));
        try r.expect(result == .lost, "renew by owner {s} with fence {d} of a claim of s10-w1 with fence {d} answered {t}, not lost", .{ owner, other.fence, held.fence, result });
    }
    try r.expectSame(longer, try r.fetch(job, "k1"), &.{}, "a renew that answered lost");

    // Leases that expired and that nobody took: still the owner's, to renew
    // and to finish (A6).
    for ([_][]const u8{ "k2", "k3", "k4" }) |key| _ = try r.create(job, key, .{ .after = .zero });
    const three = try r.claim("s10-w1", &.{job}, &.{}, 3, r.ms(1000));
    try r.expect(three.claimed.len == 3, "a claim of 3 due records took {d}", .{three.claimed.len});
    for (three.claimed) |c| try r.waitPast(c.record.lease_until.?);
    const late = three.claimed[0].record;
    const kept = try r.renew(late, "s10-w1", r.ms(60_000));
    try r.expect(kept == .renewed, "renew of a lease that expired and that no claim took answered {t}, not renewed", .{kept});
    const over = three.claimed[2].record;
    const ended = try r.finish(r.finishOf(over, "s10-w1", .{ .done = .{ .state = .succeeded, .keep = .forever } }));
    try r.expect(ended == .done, "finish of a lease that expired and that no claim took answered {t}, not done", .{ended});
    const done = try r.fetch(job, over.key);
    try r.expect(done.state == .succeeded and done.owner == null, "a finish to done of a lease that expired left {s}/{s} {t}", .{ job, over.key, done.state });
    // The same owner on a takeover: its old fence is lost.
    const old = three.claimed[1].record;
    _ = try r.takeOver("s10-w1", old, r.ms(60_000));
    const stale = try r.renew(old, "s10-w1", r.ms(60_000));
    try r.expect(stale == .lost, "renew of the fence before a takeover by the same owner answered {t}, not lost", .{stale});
    // A removed record: removed.
    try r.expect(try r.remove(job, "k1"), "remove of a running record returned false", .{});
    const gone = try r.renew(held, "s10-w1", r.ms(60_000));
    try r.expect(gone == .removed, "renew of a removed record answered {t}, not removed", .{gone});
}

/// Fails unless `next_in` of `result` is the time from the claim, made
/// between the store's `t0` and `t1`, to `at`, within the slack.
fn expectNextIn(r: *Runner, result: Store.ClaimResult, at: Instant, t0: Instant, t1: Instant, comptime what: []const u8) Error!void {
    const next_in = result.next_in orelse return r.fail("next_in of " ++ what ++ " is null", .{});
    try r.expectNear(at.add(.fromNanoseconds(-next_in.nanoseconds)), t0, t1, .zero, "the moment of a claim by its next_in to " ++ what);
}

pub fn s14(r: *Runner) Error!void {
    const job = "s14-send";
    const lease = r.ms(60_000);
    const empty = try r.claim("s14-w1", &.{}, &.{job}, 5, lease);
    try r.expect(empty.claimed.len == 0 and empty.next_in == null, "a claim of a job without records gave {d} records, next_in {?f}", .{ empty.claimed.len, empty.next_in });
    // The nearest record this claim would take: not one of another job, or
    // paused, though due sooner.
    _ = try r.create(job, "soon", .{ .after = .fromSeconds(30) });
    _ = try r.create("s14-other", "k1", .{ .after = .fromSeconds(1) });
    _ = try r.create(job, "paused", .{ .after = .zero });
    _ = try r.updated(try r.fetch(job, "paused"), .{ .state = .paused });
    const soon = try r.fetch(job, "soon");
    var t0 = r.now();
    const waiting = try r.claim("s14-w1", &.{}, &.{job}, 5, lease);
    var t1 = r.now();
    try r.expect(waiting.claimed.len == 0, "a claim took a record due in 30 s, or a paused one", .{});
    try expectNextIn(r, waiting, soon.run_at.?, t0, t1, "a record due in 30 s");
    // A running record counts from its lease_until.
    const leased = try r.running(job, "leased", "s14-w1", r.ms(10_000));
    t0 = r.now();
    const other = try r.claim("s14-w2", &.{}, &.{job}, 5, lease);
    t1 = r.now();
    try r.expect(other.claimed.len == 0, "a claim took a record of a live lease", .{});
    try expectNextIn(r, other, leased.lease_until.?, t0, t1, "a lease of 10 s");
}

pub fn s15(r: *Runner) Error!void {
    _ = try r.create("s15-send", "k1", .{ .after = .zero });
    const t0 = r.now();
    const result = try r.claim("s15-w1", &.{"s15-send"}, &.{}, 1, r.ms(60_000));
    const t1 = r.now();
    try r.expect(result.claimed.len == 1, "a claim of a due record took {d}", .{result.claimed.len});
    try r.expectNear(result.claimed[0].record.claimed_at, t0, t1, .zero, "claimed_at of a claim right after now");
}

pub fn s21(r: *Runner) Error!void {
    const job = "s21-send";
    const owner = "s21-w1";
    const old = try r.running(job, "k1", owner, r.ms(60_000));
    try r.expect(try r.remove(job, "k1"), "remove of a running record returned false", .{});
    // A new life of the key, claimed by the same owner with the same fence.
    const fresh = try r.running(job, "k1", owner, r.ms(60_000));
    try r.expect(fresh.fence == old.fence and !std.mem.eql(u8, &fresh.life, &old.life), "the claim of a new life of a key has fence {d}, not {d}, or the life before", .{ fresh.fence, old.fence });
    const renewed = try r.renew(old, owner, r.ms(60_000));
    try r.expect(renewed == .removed, "renew of the claim of a removed life answered {t}, not removed", .{renewed});
    var request = r.finishOf(old, owner, .{ .done = .{ .state = .succeeded, .keep = .forever } });
    const rows = [_]model.Run{Runner.rowOf(old, .succeeded, null, owner)};
    request.history = .{ .runs = &rows, .keep = .forever };
    const finished = try r.finish(request);
    try r.expect(finished == .lost, "finish of the claim of a removed life answered {t}, not lost", .{finished});
    try r.expectSame(fresh, try r.fetch(job, "k1"), &.{}, "the renew and finish of a removed life");
    const history = try r.historyAll(.{ .job = job, .key = "k1" }, 10);
    try r.expect(history.len == 1 and std.mem.eql(u8, &history[0].life, &old.life) and history[0].fence == old.fence, "the row of the claim of a removed life is not under its life and fence: {d} rows", .{history.len});
}

pub fn s22(r: *Runner) Error!void {
    const lease = r.ms(60_000);
    for ([_][]const u8{ "s22-a", "s22-b" }) |job| {
        for ([_][]const u8{ "", "k1" }) |key| _ = try r.create(job, key, .{ .after = .zero });
    }
    // Of a job of any_key, the declared record too; of keyed_only, never.
    const taken = try r.claim("s22-w1", &.{"s22-a"}, &.{"s22-b"}, 10, lease);
    try r.expect(taken.claimed.len == 3, "a claim of 3 records it may take took {d}", .{taken.claimed.len});
    for (taken.claimed) |c| {
        try r.expect(!std.mem.eql(u8, c.record.job, "s22-b") or c.record.key.len > 0, "a claim took the declared record of a job of keyed_only", .{});
    }
    for (0..3) |_| {
        const again = try r.claim("s22-w2", &.{}, &.{"s22-b"}, 10, lease);
        try r.expect(again.claimed.len == 0, "a claim of keyed_only took the declared record of its job", .{});
    }
    const parked = try r.fetch("s22-b", "");
    try r.expect(parked.state == .pending and parked.attempt == 0, "the declared record of a job of keyed_only is {t} with attempt {d}", .{ parked.state, parked.attempt });
    // Out of next_in: with the keyed record gone, nothing is due; with one
    // due in 30 s, next_in counts that one.
    for (taken.claimed) |c| {
        if (std.mem.eql(u8, c.record.job, "s22-b")) try r.finished(r.finishOf(c.record, "s22-w1", .delete));
    }
    const none = try r.claim("s22-w2", &.{}, &.{"s22-b"}, 10, lease);
    try r.expect(none.claimed.len == 0 and none.next_in == null, "a claim of keyed_only with only its declared record due gave {d} records, next_in {?f}", .{ none.claimed.len, none.next_in });
    _ = try r.create("s22-b", "k2", .{ .after = .fromSeconds(30) });
    const k2 = try r.fetch("s22-b", "k2");
    const t0 = r.now();
    const later = try r.claim("s22-w2", &.{}, &.{"s22-b"}, 10, lease);
    const t1 = r.now();
    try expectNextIn(r, later, k2.run_at.?, t0, t1, "a record due in 30 s beside a parked declared one");
    // A claim of the job in any_key takes it.
    const declared = try r.claim("s22-w3", &.{"s22-b"}, &.{}, 10, lease);
    try r.expect(declared.claimed.len == 1 and declared.claimed[0].record.key.len == 0, "a claim of any_key did not take the declared record of its job: {d} records", .{declared.claimed.len});
}
