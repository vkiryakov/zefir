//! The checks of outcomes in `scheduler.testing.conformance`: finishes,
//! the history, retention, deadlines and cancellation, lost replies, and a
//! mix of every operation from 16 tasks, after which the invariants hold.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const Store = @import("../../Store.zig");
const Instant = @import("../../Instant.zig");
const model = @import("../../record.zig");
const Op = @import("../FaultyStore.zig").Op;
const Runner = @import("runner.zig");
const Error = Runner.Error;
const Record = model.Record;

pub fn s11(r: *Runner) Error!void {
    const job = "s11-send";
    const owner = "s11-w1";
    const lease = r.ms(60_000);
    const at: Instant = .fromUnixMs(r.now().unix_ms + 3_600_000);
    const scheduled: Instant = .fromUnixMs(1_793_000_000_000);
    const unreadable: Instant = .fromUnixMs(1_793_000_000_123);
    // Each kind of next, on a run asked to pause: every transition clears
    // pause_requested, and the store writes the times of `.after`, of the
    // last run and of the finish.
    const kinds = [_]Store.Next{
        .{ .wait = .{ .state = .pending, .run_at = .{ .at = at }, .scheduled_at = null, .attempt = 2 } },
        .{ .wait = .{ .state = .paused, .run_at = .{ .after = .fromSeconds(7200) }, .scheduled_at = scheduled, .attempt = 0, .unreadable_since = unreadable } },
        .{ .done = .{ .state = .succeeded, .keep = .{ .keep_for = .fromSeconds(3600) } } },
        .{ .done = .{ .state = .failed, .keep = .forever } },
    };
    for (kinds, [_][]const u8{ "pending", "paused", "succeeded", "failed" }) |next, key| {
        const asked = try r.updated(try r.running(job, key, owner, lease), .{ .pause_requested = true });
        var request = r.finishOf(asked, owner, next);
        request.last = Runner.lastOf(asked, .failed, "Declined");
        const t0 = r.now();
        try r.finished(request);
        const t1 = r.now();
        const rec = try r.fetch(job, key);
        try r.expect(!rec.pause_requested and rec.revision == asked.revision and rec.fence == asked.fence, "finish to {s} left pause_requested, or changed revision or fence", .{key});
        const last = rec.last orelse return r.fail("finish to {s} with a last run left none", .{key});
        try r.expect(last.outcome == .failed and std.mem.eql(u8, last.error_name orelse "", "Declined") and last.attempt == asked.attempt and last.started_at.unix_ms == request.last.?.started_at.unix_ms, "finish to {s} wrote another last run", .{key});
        try r.expectNear(last.finished_at, t0, t1, .zero, "finished_at of a last run");
        switch (next) {
            .wait => |wait| {
                try r.expect(rec.state == wait.state and rec.attempt == wait.attempt and (rec.unreadable_since == null) == (wait.unreadable_since == null), "finish to wait {t} gave {t}, attempt {d}", .{ wait.state, rec.state, rec.attempt });
                if (wait.unreadable_since) |u| try r.expect(rec.unreadable_since.?.unix_ms == u.unix_ms, "finish to wait wrote unreadable_since {?f}, not {f}", .{ rec.unreadable_since, u });
                switch (wait.run_at) {
                    .at => |moment| try r.expect(rec.run_at.?.unix_ms == moment.unix_ms and rec.scheduled_at.unix_ms == moment.unix_ms, "finish to wait .at gave run_at {?f} and scheduled_at {f}", .{ rec.run_at, rec.scheduled_at }),
                    .after => |d| {
                        try r.expectNear(rec.run_at, t0, t1, d, "run_at of a finish to wait .after 2 h");
                        try r.expect(rec.scheduled_at.unix_ms == scheduled.unix_ms, "finish to wait with a scheduled_at gave {f}", .{rec.scheduled_at});
                    },
                }
            },
            .done => |done| {
                try r.expect(rec.state == done.state, "finish to done {t} gave {t}", .{ done.state, rec.state });
                try r.expectNear(rec.finished_at, t0, t1, .zero, "finished_at of a finish to done");
                switch (done.keep) {
                    .keep_for => |d| try r.expectNear(rec.expires_at, rec.finished_at.?, rec.finished_at.?, d, "expires_at of done kept for 1 h"),
                    else => try r.expect(rec.expires_at == null, "done kept always has an expires_at", .{}),
                }
            },
            .delete => unreachable,
        }
    }
    // last null leaves the last run alone, and a wait without
    // unreadable_since clears it.
    const first = try r.running(job, "last", owner, lease);
    var request = r.finishOf(first, owner, .{ .wait = .{ .state = .pending, .run_at = .{ .after = .zero }, .scheduled_at = null, .attempt = 1, .unreadable_since = unreadable } });
    try r.finished(request);
    const kept = try r.fetch(job, "last");
    const claim = try r.claim(owner, &.{job}, &.{}, 1, lease);
    try r.expect(claim.claimed.len == 1, "a claim of the due record {s}/last took {d}", .{ job, claim.claimed.len });
    request = r.finishOf(claim.claimed[0].record, owner, .{ .wait = .{ .state = .pending, .run_at = .{ .at = at }, .scheduled_at = null, .attempt = 0 } });
    request.last = null;
    try r.finished(request);
    const untouched = try r.fetch(job, "last");
    try r.expect(untouched.unreadable_since == null, "a wait without unreadable_since kept it", .{});
    try r.expectSame(kept, untouched, &.{ "attempt", "fence", "run_at", "scheduled_at", "unreadable_since" }, "a finish with last null");

    // Delete; another owner or fence: lost; another revision: changed.
    const gone = try r.running(job, "delete", owner, lease);
    try r.finished(r.finishOf(gone, owner, .delete));
    try r.expect(try r.get(job, "delete") == null, "finish to delete left the record", .{});
    const run = try r.running(job, "lost", owner, lease);
    var stranger = run;
    stranger.fence +%= 1;
    for ([_][]const u8{ "s11-w2", owner }, [_]Record{ run, stranger }) |who, of| {
        const result = try r.finish(r.finishOf(of, who, .delete));
        try r.expect(result == .lost, "finish by {s} with fence {d} of a claim of {s} with fence {d} answered {t}, not lost", .{ who, of.fence, owner, run.fence, result });
    }
    const moved = try r.updated(run, .{ .pause_requested = true });
    const result = try r.finish(r.finishOf(run, owner, .delete));
    switch (result) {
        .changed => |now| try r.expectSame(moved, now, &.{}, "the record of changed"),
        else => return r.fail("finish on revision {d} of a record of revision {d} answered {t}, not changed", .{ run.revision, moved.revision, result }),
    }
    // After remove: lost, and the row written all the same.
    try r.expect(try r.remove(job, "lost"), "remove of a running record returned false", .{});
    var late = r.finishOf(moved, owner, .{ .done = .{ .state = .succeeded, .keep = .forever } });
    const rows = [_]model.Run{Runner.rowOf(moved, .succeeded, null, owner)};
    late.history = .{ .runs = &rows, .keep = .forever };
    const removed = try r.finish(late);
    try r.expect(removed == .lost, "finish of a removed record answered {t}, not lost", .{removed});
    const history = try r.historyAll(.{ .job = job, .key = "lost" }, 7);
    try r.expect(history.len == 1 and history[0].fence == moved.fence and history[0].outcome == .succeeded, "the row of a finish of a removed record: {d} rows", .{history.len});
}

/// Writes `rows` through a finish of no claim: refused as lost, it writes
/// them all the same. Each finish comes 5 ms after the one before, so its
/// rows end in a millisecond of their own and "the newest first" says
/// something.
fn writeRows(r: *Runner, rows: []const model.Run) Error!void {
    try r.sleep(.fromMilliseconds(5));
    const result = try r.finish(.{ .ref = .{ .job = "s12-none", .key = "none" }, .life = @splat(0), .owner = "s12-none", .fence = 1, .revision = 0, .tag = r.newTag(), .next = .delete, .last = null, .history = .{ .runs = rows, .keep = .forever } });
    try r.expect(result == .lost, "finish of a record that is not there answered {t}, not lost", .{result});
}

pub fn s12(r: *Runner) Error!void {
    const job = "s12-send";
    const run = try r.running(job, "k1", "s12-w1", r.ms(60_000));
    const abandoned = Runner.rowOf(run, .abandoned, null, "s12-w2");
    const own = Runner.rowOf(run, .succeeded, null, "s12-w1");
    var skipped = Runner.rowOf(run, .skipped, null, "s12-w1");
    skipped.fence = 2;
    skipped.tenant = "acme";
    var other_key = Runner.rowOf(run, .abandoned, null, "s12-w2");
    other_key.fence = 3;
    other_key.key = "k2";
    other_key.tenant = "acme";
    var other_job = Runner.rowOf(run, .succeeded, null, "s12-w3");
    other_job.job = "s12-other";
    other_job.life = r.newLife();
    other_job.tenant = "acme";
    // The same row again is one row; the owner's row replaces the abandoned
    // one of its (life, fence), and no row replaces the owner's.
    try writeRows(r, &.{abandoned});
    try writeRows(r, &.{abandoned});
    try writeRows(r, &.{own});
    try writeRows(r, &.{Runner.rowOf(run, .failed, "Declined", "s12-w1")});
    try writeRows(r, &.{ skipped, other_key });
    try writeRows(r, &.{other_job});
    const of_key = try r.historyAll(.{ .job = job, .key = "k1" }, 2);
    try r.expect(of_key.len == 2, "history of a key gave {d} rows, not 2", .{of_key.len});
    for (of_key) |row| {
        if (row.fence != 1) continue;
        try r.expect(row.outcome == .succeeded and std.mem.eql(u8, row.instance, "s12-w1"), "the row of fence 1 is {t} of {s}, not the owner's succeeded one", .{ row.outcome, row.instance });
    }
    // Each query: its rows only, each once, the newest first, a page of 2.
    const filters = [_]model.HistoryFilter{ .{ .job = job }, .{ .tenant = "acme" }, .{ .outcome = .skipped }, .{ .outcome = .abandoned }, .{ .outcome = .failed }, .{ .job = job, .outcome = .succeeded } };
    for (filters, [_]usize{ 3, 3, 1, 1, 0, 1 }) |filter, count| {
        const rows = try r.historyAll(filter, 2);
        try r.expect(rows.len == count, "history of job {?s}, tenant {?s}, outcome {?t} gave {d} rows, not {d}", .{ filter.job, filter.tenant, filter.outcome, rows.len, count });
    }
}

pub fn s13(r: *Runner) Error!void {
    const job = "s13-send";
    const owner = "s13-w1";
    const brief = r.ms(1000);
    // Kept for a second, for an hour and always: a record and its row each.
    const keeps = [_]model.Retention{ .{ .keep_for = brief }, .{ .keep_for = .fromSeconds(3600) }, .forever };
    const keys = [_][]const u8{ "brief", "hour", "always" };
    var expires: Instant = undefined;
    for (keeps, keys) |keep, key| {
        const run = try r.running(job, key, owner, r.ms(60_000));
        var request = r.finishOf(run, owner, .{ .done = .{ .state = .succeeded, .keep = keep } });
        const rows = [_]model.Run{Runner.rowOf(run, .succeeded, null, owner)};
        request.history = .{ .runs = &rows, .keep = keep };
        const t0 = r.now();
        try r.finished(request);
        const t1 = r.now();
        const rec = try r.fetch(job, key);
        const row = try r.historyAll(.{ .job = job, .key = key }, 7);
        try r.expect(row.len == 1, "history of a finished record gave {d} rows, not 1", .{row.len});
        switch (keep) {
            .keep_for => |d| {
                try r.expectNear(rec.expires_at, t0, t1, d, "expires_at of a record kept for a time");
                try r.expectNear(row[0].expires_at, t0, t1, d, "expires_at of a row kept for a time");
            },
            else => try r.expect(rec.expires_at == null and row[0].expires_at == null, "a record or row kept always has an expires_at", .{}),
        }
        if (std.mem.eql(u8, key, "brief")) expires = .fromUnixMs(@max(rec.expires_at.?.unix_ms, row[0].expires_at.?.unix_ms));
    }
    // Gone within expiry_lag of their expires_at; the others stay.
    const lag = r.setup.expiry_lag.nanoseconds *| @max(r.options.time_scale, 1);
    try r.waitPast(expires.add(.fromNanoseconds(lag)));
    try r.expect(try r.get(job, "brief") == null, "a record kept for a second was still there after its expires_at and expiry_lag", .{});
    const rows = try r.historyAll(.{ .job = job }, 7);
    try r.expect(rows.len == 2, "history after a row expired gave {d} rows, not 2", .{rows.len});
    for (keys[1..]) |key| _ = try r.fetch(job, key);
}

/// Fails unless `result` is the error `expected`.
fn expectRefused(r: *Runner, result: anytype, expected: Store.StoreError, comptime what: []const u8) Error!void {
    if (result) |_| {
        return r.fail(what ++ " succeeded, not error.{t}", .{expected});
    } else |err| {
        if (err != expected) return r.fail(what ++ " returned error.{t}, not error.{t}", .{ err, expected });
    }
}

pub fn s16(r: *Runner) Error!void {
    const job = "s16-send";
    const owner = "s16-w1";
    const held = try r.running(job, "held", owner, r.ms(60_000));
    _ = try r.create(job, "due", .{ .after = .zero });
    const due = try r.fetch(job, "due");
    const io = r.io;
    const s = r.store();
    const rows = [_]model.Run{Runner.rowOf(held, .succeeded, null, owner)};
    var finish = r.finishOf(held, owner, .{ .done = .{ .state = .succeeded, .keep = .forever } });
    finish.history = .{ .runs = &rows, .keep = .forever };
    const contexts = [_]*const fn (*const Runner) core.Context{ Runner.nearlyExpired, Runner.cancelled };
    const expected = [_]Store.StoreError{ error.DeadlineExceeded, error.Cancelled };
    for (contexts, expected) |context, err| {
        try expectRefused(r, s.create(io, context(r), &.{ .job = job, .key = "new", .life = r.newLife(), .plan = "", .payload = "{}", .run_at = .{ .after = .zero } }, r.call()), err, "create");
        try expectRefused(r, s.get(io, context(r), &.{ .job = job, .key = "due" }, r.call()), err, "get");
        try expectRefused(r, s.update(io, context(r), &.{ .ref = Runner.refOf(due), .expect = .{ .life = due.life, .revision = due.revision, .state = .pending }, .set = .{ .state = .paused }, .tag = r.newTag() }, r.call()), err, "update");
        try expectRefused(r, s.remove(io, context(r), &.{ .job = job, .key = "due" }, r.call()), err, "remove");
        try expectRefused(r, s.list(io, context(r), &.{ .filter = .{}, .page = .{} }, r.call()), err, "list");
        try expectRefused(r, s.claim(io, context(r), &.{ .owner = "s16-w2", .any_key = &.{job}, .keyed_only = &.{}, .max = 10, .lease = r.ms(60_000), .tag = r.newTag() }, r.call()), err, "claim");
        try expectRefused(r, s.renew(io, context(r), &.{ .ref = Runner.refOf(held), .life = held.life, .owner = owner, .fence = held.fence, .lease = .fromSeconds(7200) }, r.call()), err, "renew");
        try expectRefused(r, s.finish(io, context(r), &finish, r.call()), err, "finish");
        try expectRefused(r, s.history(io, context(r), &.{ .filter = .{}, .page = .{} }, r.call()), err, "history");
    }
    // Nothing was done.
    try r.expect(try r.get(job, "new") == null, "a create that failed before it was sent made a record", .{});
    try r.expectSame(due, try r.fetch(job, "due"), &.{}, "the calls that failed before they were sent");
    try r.expectSame(held, try r.fetch(job, "held"), &.{}, "the calls that failed before they were sent");
    const history = try r.historyAll(.{}, 7);
    try r.expect(history.len == 0, "a finish that failed before it was sent wrote {d} rows", .{history.len});
}

/// Asks the harness to lose the reply of the next call of `op`.
fn lose(r: *Runner, op: Op) Error!void {
    const hook = r.harness.lose_next_reply orelse return r.skip("the harness has no loseNextReply");
    hook(r.harness.ptr, r.io, op) catch |err| return r.fail("harness.loseNextReply(.{t}) returned error.{t}", .{ op, err });
}

/// The answer of a call whose reply was lost: what it returned, or null
/// for OutcomeUnknown; another error fails the check.
fn answer(r: *Runner, result: anytype, comptime what: []const u8) Error!?@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.OutcomeUnknown => null,
        else => r.fail(what ++ " with its reply lost returned error.{t}: {s}", .{ err, r.diag.message() }),
    };
}

pub fn s17(r: *Runner) Error!void {
    const job = "s17-send";
    const owner = "s17-w1";
    const long = r.ms(60_000);
    const short = r.ms(1000);
    const io = r.io;
    // create: created (or replaced: either says the record is of this
    // life), never existing; over a live record, existing, never created.
    var create: Store.CreateRequest = .{ .job = job, .key = "k1", .life = r.newLife(), .plan = "", .payload = "{}", .run_at = .{ .after = .fromSeconds(3600) } };
    try lose(r, .create);
    if (try answer(r, r.store().create(io, r.ctx(), &create, r.call()), "create")) |result| {
        try r.expect(result != .existing, "create of a free key with its reply lost answered existing", .{});
        try r.expect(std.mem.eql(u8, &(try r.fetch(job, "k1")).life, &create.life), "create with its reply lost answered {t}, and the record is of another life", .{result});
    }
    const live = (try r.get(job, "k1")) orelse made: {
        _ = try r.need(r.store().create(io, r.ctx(), &create, r.call()), "create");
        break :made try r.fetch(job, "k1");
    };
    create.life = r.newLife();
    try lose(r, .create);
    if (try answer(r, r.store().create(io, r.ctx(), &create, r.call()), "create of a live key")) |result|
        try r.expect(result == .existing, "create of a live key with its reply lost answered {t}, not existing", .{result});
    try r.expectSame(live, try r.fetch(job, "k1"), &.{}, "a create of a live key with its reply lost");

    // update: updated, the revision one more, never conflict or not_found;
    // applied whole or not at all.
    try lose(r, .update);
    const update: Store.UpdateRequest = .{ .ref = Runner.refOf(live), .expect = .{ .life = live.life, .revision = live.revision, .state = live.state }, .set = .{ .pause_requested = true }, .tag = r.newTag() };
    if (try answer(r, r.store().update(io, r.ctx(), &update, r.call()), "update")) |result| switch (result) {
        .updated => |revision| try r.expect(revision == live.revision +% 1, "update with its reply lost answered revision {d}, not {d}", .{ revision, live.revision +% 1 }),
        else => return r.fail("update with its reply lost answered {t}, not updated", .{result}),
    };
    const changed = try r.fetch(job, "k1");
    try r.expect(changed.pause_requested == (changed.revision == live.revision +% 1), "update with its reply lost applied in part: revision {d}, pause_requested {}", .{ changed.revision, changed.pause_requested });

    // renew: renewed, never lost or removed.
    const held = try r.running(job, "k2", owner, long);
    try lose(r, .renew);
    if (try answer(r, r.store().renew(io, r.ctx(), &.{ .ref = Runner.refOf(held), .life = held.life, .owner = owner, .fence = held.fence, .lease = long }, r.call()), "renew")) |result|
        try r.expect(result == .renewed, "renew with its reply lost answered {t}, not renewed", .{result});

    // finish that applied: done, never lost or changed; of a claim taken
    // over: lost, never done.
    for ([_]Store.Next{ .{ .done = .{ .state = .succeeded, .keep = .forever } }, .delete }, [_][]const u8{ "k3", "k4" }) |next, key| {
        const run = try r.running(job, key, owner, long);
        const request = r.finishOf(run, owner, next);
        try lose(r, .finish);
        if (try answer(r, r.store().finish(io, r.ctx(), &request, r.call()), "finish")) |result|
            try r.expect(result == .done, "finish with its reply lost answered {t}, not done", .{result});
    }
    const old = try r.running(job, "k5", owner, short);
    const took = try r.takeOver("s17-w2", old, long);
    const request = r.finishOf(old, owner, .{ .done = .{ .state = .succeeded, .keep = .forever } });
    try lose(r, .finish);
    if (try answer(r, r.store().finish(io, r.ctx(), &request, r.call()), "finish of a claim taken over")) |result|
        try r.expect(result == .lost, "finish of a claim taken over with its reply lost answered {t}, not lost", .{result});
    try r.expectSame(took.record, try r.fetch(job, "k5"), &.{}, "a finish of a claim taken over with its reply lost");

    // A claim of three: each record it gave is its own, and none twice;
    // another claim takes the rest after the lease, and between them the
    // two took each of the three once.
    for ([_][]const u8{ "t1", "t2", "t3" }) |key| _ = try r.create("s17-three", key, .{ .after = .zero });
    const start = r.now();
    try lose(r, .claim);
    const claimed = try answer(r, r.store().claim(io, r.ctx(), &.{ .owner = owner, .any_key = &.{}, .keyed_only = &.{"s17-three"}, .max = 3, .lease = short, .tag = r.newTag() }, r.call()), "claim");
    const given: []const Store.Claimed = if (claimed) |result| result.claimed else &.{};
    try r.expect(given.len <= 3, "a claim of at most 3 with its reply lost gave {d} records", .{given.len});
    var by: [3]Giver = @splat(.none);
    for (given) |c| {
        try r.expectShape(c.record, "a claim with its reply lost");
        try r.expect(c.record.state == .running and std.mem.eql(u8, c.record.owner orelse "", owner) and c.record.fence == 1 and std.mem.eql(u8, c.record.job, "s17-three"), "a claim with its reply lost gave {s}/{s}, not running with its owner and fence 1", .{ c.record.job, c.record.key });
        try noteGiven(r, &by, c.record, .lost);
        const renewed = try r.renew(c.record, owner, long);
        try r.expect(renewed == .renewed, "renew of {s}, which a claim with its reply lost gave, answered {t}", .{ c.record.key, renewed });
    }
    try r.waitPast(start.add(short));
    const give_up = Io.Clock.awake.now(io).addDuration(r.ms(10_000));
    while (std.mem.findScalar(Giver, &by, .none) != null) {
        const result = try r.claim("s17-w2", &.{}, &.{"s17-three"}, 3, long);
        for (result.claimed) |c| try noteGiven(r, &by, c.record, .again);
        if (std.mem.findScalar(Giver, &by, .none) == null) break;
        if (Io.Clock.awake.now(io).nanoseconds > give_up.nanoseconds) {
            const left = std.mem.count(Giver, &by, &.{.none});
            return r.fail("{d} records that a claim with its reply lost did not give were not claimed again within 10 s after its lease", .{left});
        }
        try r.sleep(r.ms(50));
    }
    // After it all, the invariants hold.
    _ = try r.listAll(.{}, 7);
    _ = try r.historyAll(.{}, 7);
}

/// Which claim gave each of t1, t2 and t3 of the claim of three in S17:
/// the one whose reply was lost, or one after its lease.
const Giver = enum { none, lost, again };

/// Notes that a claim of S17 gave `rec`, which must be t1, t2 or t3 of
/// s17-three and given by no claim before.
fn noteGiven(r: *Runner, by: *[3]Giver, rec: Record, giver: Giver) Error!void {
    const keys = [_][]const u8{ "t1", "t2", "t3" };
    const i = for (keys, 0..) |key, k| {
        if (std.mem.eql(u8, rec.job, "s17-three") and std.mem.eql(u8, rec.key, key)) break k;
    } else return r.fail("a claim of s17-three gave {s}/{s}, which is none of its records", .{ rec.job, rec.key });
    switch (by[i]) {
        .none => by[i] = giver,
        .lost => if (giver == .lost)
            return r.fail("a claim with its reply lost gave {s}/{s} twice", .{ rec.job, rec.key })
        else
            return r.fail("a claim took {s}/{s}, which a claim with its reply lost gave and its owner renewed", .{ rec.job, rec.key }),
        .again => return r.fail("a claim took {s}/{s}, which another claim took after the lease", .{ rec.job, rec.key }),
    }
}

/// The records of the mix: 8 keys of s20-a, 8 of s20-b, and the declared
/// record of s20-b, which only the tasks that declare s20-b may claim.
const slots: [17]model.Ref = slots: {
    const keys = [_][]const u8{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7" };
    var all: [17]model.Ref = undefined;
    for (keys, 0..) |k, i| {
        all[i] = .{ .job = "s20-a", .key = k };
        all[keys.len + i] = .{ .job = "s20-b", .key = k };
    }
    all[16] = .{ .job = "s20-b", .key = "" };
    break :slots all;
};

/// A claim that a task of the mix holds.
const Held = struct { slot: u8, life: model.Life, fence: u64, revision: u64, attempt: u32, scheduled_at: Instant, claimed_at: Instant };

/// The life, fence and revision of a record that a claim gave.
const Note = struct {
    life: model.Life,
    fence: u64,
    revision: u64,

    fn lessThan(_: void, a: Note, b: Note) bool {
        return switch (std.mem.order(u8, &a.life, &b.life)) {
            .lt => true,
            .gt => false,
            .eq => a.fence < b.fence,
        };
    }
};

/// A record of `life` paused or finished at `revision`: only a change of
/// the client, which raises the revision, makes it claimable again.
const Quiet = struct { life: model.Life, revision: u64 };

/// A record made quiet by the finish of its claim `fence`, or by a change
/// of the client (`fence` 0): the claims up to `fence` came before.
const QuietNote = struct { quiet: Quiet, fence: u64 };

/// One task of S20: every operation of the contract at random, on its own
/// claims, as a worker and a client at once.
const Mixer = struct {
    r: *Runner,
    stop: *const std.atomic.Value(bool),
    index: u8,
    owner: [7]u8,
    /// Whether the task declares s20-b: its claims take the declared record.
    declares: bool,
    rng: std.Random.DefaultPrng,
    arena: std.heap.ArenaAllocator,
    held: std.ArrayList(Held) = .empty,
    claims: std.ArrayList(Note) = .empty,
    quiets: std.ArrayList(QuietNote) = .empty,
    lives: u64 = 0,
    /// The first rule the task saw broken, and how many times one was.
    problem: ?[]const u8 = null,
    problems: usize = 0,

    fn init(r: *Runner, stop: *const std.atomic.Value(bool), index: u8) Mixer {
        return .{
            .r = r,
            .stop = stop,
            .index = index,
            .owner = .{ 's', '2', '0', '-', 'w', '0' + index / 10, '0' + index % 10 },
            .declares = index % 2 == 0,
            .rng = .init(index),
            .arena = .init(r.gpa),
        };
    }

    fn deinit(m: *Mixer) void {
        m.arena.deinit();
        m.held.deinit(m.r.gpa);
        m.claims.deinit(m.r.gpa);
        m.quiets.deinit(m.r.gpa);
    }

    fn run(m: *Mixer) void {
        while (!m.stop.load(.acquire)) {
            _ = m.arena.reset(.retain_capacity);
            m.step(m.rng.random()) catch |err| m.fail(@errorName(err));
            m.r.io.sleep(.fromMicroseconds(50), .awake) catch return;
        }
    }

    fn fail(m: *Mixer, problem: []const u8) void {
        if (m.problem == null) m.problem = problem;
        m.problems += 1;
    }

    fn see(m: *Mixer, rec: Record) void {
        if (Runner.shape(rec)) |problem| m.fail(problem);
    }

    fn options(m: *Mixer) Store.CallOptions {
        return .{ .allocator = m.arena.allocator() };
    }

    fn step(m: *Mixer, random: std.Random) !void {
        const s = m.r.store();
        const io = m.r.io;
        const slot = &slots[random.uintLessThan(usize, slots.len)];
        const later: Store.Moment = .{ .after = .fromMilliseconds(random.intRangeAtMost(i64, -200, 300)) };
        switch (random.uintLessThan(u8, 15)) {
            0, 1 => {
                m.lives += 1;
                var life: model.Life = @splat(0);
                life[0] = m.index;
                std.mem.writeInt(u64, life[1..9], m.lives, .little);
                _ = try s.create(io, m.r.ctx(), &.{ .job = slot.job, .key = slot.key, .life = life, .plan = "", .payload = "{}", .run_at = later }, m.options());
            },
            2 => if (try s.get(io, m.r.ctx(), slot, m.options())) |rec| m.see(rec),
            3, 4 => try m.update(slot, later, random),
            // Records of s20-a are never removed: a claim that a task drops
            // lives until its lease ends, and another claim takes it over.
            5 => _ = try s.remove(io, m.r.ctx(), &slots[8 + random.uintLessThan(usize, 9)], m.options()),
            6 => {
                const page = try s.list(io, m.r.ctx(), &.{ .filter = .{}, .page = .{ .limit = 5 } }, m.options());
                for (page.records) |rec| m.see(rec);
            },
            7, 8, 9 => try m.claim(random),
            10 => if (m.held.items.len != 0) {
                const i = random.uintLessThan(usize, m.held.items.len);
                const h = m.held.items[i];
                const renewed = try s.renew(io, m.r.ctx(), &.{ .ref = slots[h.slot], .life = h.life, .owner = &m.owner, .fence = h.fence, .lease = m.r.ms(1000) }, m.options());
                if (renewed != .renewed) _ = m.held.swapRemove(i);
            },
            11, 12, 13 => try m.finish(later, random),
            else => {
                const page = try s.history(io, m.r.ctx(), &.{ .filter = .{ .job = slot.job, .key = slot.key }, .page = .{ .limit = 20 } }, m.options());
                for (page.runs, 0..) |row, k| {
                    for (page.runs[0..k]) |other| {
                        if (std.mem.eql(u8, &row.life, &other.life) and row.fence == other.fence) m.fail("two rows of one claim in a page of the history");
                    }
                }
            },
        }
    }

    /// A change of the client that fits the state the record has.
    fn update(m: *Mixer, slot: *const model.Ref, later: Store.Moment, random: std.Random) !void {
        const s = m.r.store();
        const now = (try s.get(m.r.io, m.r.ctx(), slot, m.options())) orelse return;
        m.see(now);
        const set: Store.Patch = switch (now.state) {
            .pending => switch (random.uintLessThan(u8, 3)) {
                0 => .{ .state = .paused },
                1 => .{ .run_at = later },
                else => .{ .pause_requested = random.boolean() },
            },
            .paused => if (random.boolean()) .{ .state = .pending } else .{ .run_at = later },
            .running => if (random.boolean()) .{ .pause_requested = true } else .{ .run_at = later },
            .succeeded, .failed => if (random.boolean()) .{ .reset = true } else .{ .reset = true, .state = .paused },
        };
        const request: Store.UpdateRequest = .{ .ref = slot.*, .expect = .{ .life = now.life, .revision = now.revision, .state = now.state }, .set = set, .tag = @splat(m.index) };
        switch (try s.update(m.r.io, m.r.ctx(), &request, m.options())) {
            .updated => |revision| {
                if (revision != now.revision +% 1) m.fail("update raised the revision by other than 1");
                // An update holds on the life too: the pause is of the life
                // read.
                if (set.state == .paused) try m.quiets.append(m.r.gpa, .{ .quiet = .{ .life = now.life, .revision = revision }, .fence = 0 });
            },
            .conflict => |rec| m.see(rec),
            .not_found => {},
        }
    }

    fn claim(m: *Mixer, random: std.Random) !void {
        if (m.held.items.len >= 8) return;
        const result = try m.r.store().claim(m.r.io, m.r.ctx(), &.{
            .owner = &m.owner,
            .any_key = if (m.declares) &.{ "s20-a", "s20-b" } else &.{"s20-a"},
            .keyed_only = if (m.declares) &.{} else &.{"s20-b"},
            .max = random.intRangeAtMost(u32, 1, 3),
            .lease = m.r.ms(1000),
            .tag = @splat(m.index),
        }, m.options());
        for (result.claimed) |c| {
            const rec = c.record;
            m.see(rec);
            if (rec.state != .running or !std.mem.eql(u8, rec.owner orelse "", &m.owner)) m.fail("a claim gave a record that is not running, or of another owner");
            if (rec.key.len == 0 and !m.declares) m.fail("a claim gave a declared record to a task that does not declare its job");
            const slot = for (slots, 0..) |s, i| {
                if (std.mem.eql(u8, s.job, rec.job) and std.mem.eql(u8, s.key, rec.key)) break i;
            } else {
                m.fail("a claim gave a record of a job or key it was not asked for");
                continue;
            };
            try m.claims.append(m.r.gpa, .{ .life = rec.life, .fence = rec.fence, .revision = rec.revision });
            try m.held.append(m.r.gpa, .{ .slot = @intCast(slot), .life = rec.life, .fence = rec.fence, .revision = rec.revision, .attempt = rec.attempt, .scheduled_at = rec.scheduled_at, .claimed_at = rec.claimed_at orelse .fromUnixMs(0) });
        }
    }

    /// Ends a held claim with any kind of next, or drops it as a lost
    /// instance would: after its lease, another claim takes it over. A claim
    /// that ended neither renews nor finishes again.
    fn finish(m: *Mixer, later: Store.Moment, random: std.Random) !void {
        if (m.held.items.len == 0) return;
        const i = random.uintLessThan(usize, m.held.items.len);
        const h = m.held.items[i];
        const next: Store.Next = switch (random.uintLessThan(u8, 6)) {
            0 => .{ .wait = .{ .state = .pending, .run_at = later, .scheduled_at = null, .attempt = h.attempt } },
            1 => .{ .wait = .{ .state = .paused, .run_at = later, .scheduled_at = h.scheduled_at, .attempt = 0 } },
            2 => .{ .done = .{ .state = .succeeded, .keep = .{ .keep_for = m.r.ms(300) } } },
            3 => .{ .done = .{ .state = .failed, .keep = .forever } },
            4 => .delete,
            else => {
                _ = m.held.swapRemove(i);
                return;
            },
        };
        const ref = slots[h.slot];
        const rows = [_]model.Run{.{
            .job = ref.job,
            .key = ref.key,
            .tenant = null,
            .life = h.life,
            .fence = h.fence,
            .attempt = h.attempt,
            .scheduled_at = h.scheduled_at,
            .started_at = h.claimed_at,
            .finished_at = h.claimed_at,
            .outcome = if (random.boolean()) .succeeded else .abandoned,
            .error_name = null,
            .instance = &m.owner,
            .expires_at = null,
        }};
        const request: Store.FinishRequest = .{
            .ref = ref,
            .life = h.life,
            .owner = &m.owner,
            .fence = h.fence,
            .revision = h.revision,
            .tag = @splat(m.index),
            .next = next,
            .last = .{ .outcome = .succeeded, .error_name = null, .attempt = h.attempt, .started_at = h.claimed_at, .finished_at = h.claimed_at },
            .history = .{ .runs = &rows, .keep = .{ .keep_for = m.r.ms(1000) } },
        };
        const s = m.r.store();
        switch (try s.finish(m.r.io, m.r.ctx(), &request, m.options())) {
            .done => {
                _ = m.held.swapRemove(i);
                const quiet = switch (next) {
                    .wait => |w| w.state == .paused,
                    .done => true,
                    .delete => false,
                };
                if (quiet) try m.quiets.append(m.r.gpa, .{ .quiet = .{ .life = h.life, .revision = h.revision }, .fence = h.fence });
                if (try s.finish(m.r.io, m.r.ctx(), &request, m.options()) != .lost) m.fail("a second finish of a claim that ended was not lost");
                const renewed = try s.renew(m.r.io, m.r.ctx(), &.{ .ref = ref, .life = h.life, .owner = &m.owner, .fence = h.fence, .lease = m.r.ms(1000) }, m.options());
                if (renewed == .renewed) m.fail("a claim that ended was renewed");
            },
            .lost => _ = m.held.swapRemove(i),
            .changed => |rec| {
                m.see(rec);
                // A change of the client during the run: finish again on its
                // revision.
                m.held.items[i].revision = rec.revision;
            },
        }
    }
};

pub fn s20(r: *Runner) Error!void {
    var stop: std.atomic.Value(bool) = .init(false);
    var mixers: [16]Mixer = undefined;
    for (&mixers, 0..) |*m, i| m.* = .init(r, &stop, @intCast(i));
    defer for (&mixers) |*m| m.deinit();
    {
        var group: Io.Group = .init;
        defer group.cancel(r.io);
        // On any way out, the tasks stop by the flag before the cancel.
        defer stop.store(true, .release);
        for (&mixers) |*m| group.concurrent(r.io, Mixer.run, .{m}) catch return r.fail("no task for each of 16 tasks of the mix: io.concurrent failed", .{});
        try r.sleep(.fromSeconds(3));
        stop.store(true, .release);
        group.await(r.io) catch return r.fail("the check's task was canceled while the mix ended", .{});
    }
    for (&mixers) |*m| {
        if (m.problem) |problem| return r.fail("task {d} of the mix: {s} ({d} times)", .{ m.index, problem, m.problems });
    }
    // One record a key, each of the record model; one row a claim.
    _ = try r.listAll(.{}, 5);
    _ = try r.historyAll(.{}, 50);

    // The claims of a life gave the fences 1, 2, 3, …, each once.
    var claims: std.ArrayList(Note) = .empty;
    for (&mixers) |*m| try claims.appendSlice(r.scratch, m.claims.items);
    try r.expect(claims.items.len > 0, "the mix made no claim", .{});
    std.mem.sort(Note, claims.items, {}, Note.lessThan);
    for (claims.items, 0..) |c, k| {
        const first = k == 0 or !std.mem.eql(u8, &claims.items[k - 1].life, &c.life);
        const expected = if (first) 1 else claims.items[k - 1].fence +% 1;
        try r.expect(c.fence == expected, "a claim gave fence {d} where {d} was due", .{ c.fence, expected });
    }
    // No paused or finished record was claimed: no claim after the one that
    // made a record quiet came at the revision it had then.
    var quiets: std.AutoHashMapUnmanaged(Quiet, u64) = .empty;
    for (&mixers) |*m| {
        for (m.quiets.items) |q| {
            const entry = try quiets.getOrPut(r.scratch, q.quiet);
            entry.value_ptr.* = if (entry.found_existing) @min(entry.value_ptr.*, q.fence) else q.fence;
        }
    }
    try r.expect(quiets.count() > 0, "the mix paused and finished nothing", .{});
    for (claims.items) |c| {
        const fence = quiets.get(.{ .life = c.life, .revision = c.revision }) orelse continue;
        try r.expect(c.fence <= fence, "claim {d} took a record paused or finished at revision {d}", .{ c.fence, c.revision });
    }
}
