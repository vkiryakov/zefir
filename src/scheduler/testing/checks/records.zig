//! The checks of records and their changes in
//! `scheduler.testing.conformance`: create, the times the store writes,
//! get and remove, update, list, the limits of keys, tenants and payloads,
//! and the memory of a call.

const std = @import("std");
const Store = @import("../../Store.zig");
const Instant = @import("../../Instant.zig");
const model = @import("../../record.zig");
const Runner = @import("runner.zig");
const Error = Runner.Error;
const Record = model.Record;

const trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

/// Fails unless create of `request` answers `expected`.
fn expectCreate(r: *Runner, request: *const Store.CreateRequest, expected: Store.CreateResult, comptime what: []const u8) Error!void {
    const result = try r.need(r.store().create(r.io, r.ctx(), request, r.call()), "create " ++ what);
    try r.expect(result == expected, "create " ++ what ++ " answered {t}, not {t}", .{ result, expected });
}

/// Fails unless `rec` is the record that `request` made, byte for byte,
/// before any claim or change.
fn expectFresh(r: *Runner, rec: Record, request: *const Store.CreateRequest) Error!void {
    const opt = struct {
        fn eql(a: ?[]const u8, b: ?[]const u8) bool {
            const x = a orelse return b == null;
            return std.mem.eql(u8, x, b orelse return false);
        }
    }.eql;
    const where = .{ rec.job, rec.key };
    try r.expect(std.mem.eql(u8, rec.job, request.job) and std.mem.eql(u8, rec.key, request.key), "get of {s}/{s} gave another record", where);
    try r.expect(opt(rec.tenant, request.tenant), "{s}/{s} came back with the tenant {?s}, not {?s}", .{ rec.job, rec.key, rec.tenant, request.tenant });
    try r.expect(opt(rec.trace, request.trace), "{s}/{s} came back with the trace {?s}, not {?s}", .{ rec.job, rec.key, rec.trace, request.trace });
    try r.expect(std.mem.eql(u8, rec.plan, request.plan), "{s}/{s} came back with the plan \"{s}\", not \"{s}\"", .{ rec.job, rec.key, rec.plan, request.plan });
    try r.expect(std.mem.eql(u8, rec.payload, request.payload), "{s}/{s} came back with another payload, of {d} bytes, not {d}", .{ rec.job, rec.key, rec.payload.len, request.payload.len });
    try r.expect(std.mem.eql(u8, &rec.life, &request.life), "{s}/{s} came back with another life", where);
    try r.expect(rec.state == .pending and rec.attempt == 0 and rec.fence == 0 and rec.revision == 0 and !rec.pause_requested, "{s}/{s} is new but not pending with attempt, fence and revision 0 and no pause asked", where);
    try r.expect(rec.last == null and rec.unreadable_since == null, "{s}/{s} is new but has a last run or an unreadable_since", where);
    try r.expect(rec.run_at != null and rec.run_at.?.unix_ms == rec.scheduled_at.unix_ms, "{s}/{s} is new but its run_at is not its scheduled_at", where);
    switch (request.run_at) {
        .at => |at| try r.expect(rec.scheduled_at.unix_ms == at.unix_ms, "{s}/{s} of .at {f} has run_at {f}", .{ rec.job, rec.key, at, rec.scheduled_at }),
        .after => {},
    }
}

pub fn s1(r: *Runner) Error!void {
    const job = "s1-send";
    const request: Store.CreateRequest = .{ .job = job, .key = "order-42", .tenant = "acme", .life = r.newLife(), .plan = "every 60s", .payload = "{\"order_id\":42}", .trace = trace, .run_at = .{ .after = .fromSeconds(60) } };
    try expectCreate(r, &request, .created, "of a new key");
    const first = try r.fetch(job, "order-42");
    try expectFresh(r, first, &request);

    // A live key, pending, paused or running: existing, and nothing changes.
    var again: Store.CreateRequest = .{ .job = job, .key = "order-42", .life = r.newLife(), .plan = "", .payload = "{}", .run_at = .{ .after = .zero } };
    try expectCreate(r, &again, .existing, "of a pending key");
    try r.expectSame(first, try r.fetch(job, "order-42"), &.{}, "a create that answered existing");
    const paused = try r.updated(first, .{ .state = .paused });
    try expectCreate(r, &again, .existing, "of a paused key");
    try r.expectSame(paused, try r.fetch(job, "order-42"), &.{}, "a create that answered existing");
    const claimed = try r.running(job, "order-7", "s1-worker", r.ms(60_000));
    again.key = "order-7";
    try expectCreate(r, &again, .existing, "of a running key");
    try r.expectSame(claimed, try r.fetch(job, "order-7"), &.{}, "a create that answered existing");

    // A finished key, succeeded or failed, kept for its history: replaced
    // by a record of a new life.
    for ([_]model.State{ .succeeded, .failed }, [_][]const u8{ "order-8", "order-9" }) |state, key| {
        const run = try r.running(job, key, "s1-worker", r.ms(60_000));
        try r.finished(r.finishOf(run, "s1-worker", .{ .done = .{ .state = state, .keep = .forever } }));
        var fresh = request;
        fresh.key = key;
        fresh.life = r.newLife();
        try expectCreate(r, &fresh, .replaced, "of a finished key");
        try expectFresh(r, try r.fetch(job, key), &fresh);
    }

    // The record of a declared job has the key "".
    var declared = request;
    declared.key = "";
    declared.tenant = null;
    declared.trace = null;
    declared.life = r.newLife();
    try expectCreate(r, &declared, .created, "of the key \"\"");
    try expectFresh(r, try r.fetch(job, ""), &declared);
}

pub fn s2(r: *Runner) Error!void {
    const job = "s2-send";
    // .after is the store's now and the duration, by its clock.
    const t0 = r.now();
    try r.expect(try r.create(job, "after", .{ .after = .fromSeconds(3600) }) == .created, "create of a new key did not answer created", .{});
    const t1 = r.now();
    const after = try r.fetch(job, "after");
    try r.expectNear(after.run_at, t0, t1, .fromSeconds(3600), "run_at of .after 1 h");
    try r.expectNear(after.scheduled_at, t0, t1, .fromSeconds(3600), "scheduled_at of .after 1 h");
    try r.expectNear(after.created_at, t0, t1, .zero, "created_at");

    // .at is the moment as it is, to the millisecond, at the ends of the
    // years a moment may have too.
    const moments = [_]Instant{ .fromUnixMs(1_793_018_096_789), .fromUnixMs(0), .fromUnixMs(253_402_300_799_999) };
    for (moments, [_][]const u8{ "at", "at-1970", "at-9999" }) |at, key| {
        try r.expect(try r.create(job, key, .{ .at = at }) == .created, "create of a new key did not answer created", .{});
        const rec = try r.fetch(job, key);
        try r.expect(rec.run_at != null and rec.run_at.?.unix_ms == at.unix_ms and rec.scheduled_at.unix_ms == at.unix_ms, "create .at {f} gave run_at {?f} and scheduled_at {f}", .{ at, rec.run_at, rec.scheduled_at });
    }
}

pub fn s3(r: *Runner) Error!void {
    const job = "s3-send";
    try r.expect(try r.get(job, "order-42") == null, "get of a key never created found a record", .{});
    const created = try r.create(job, "order-42", .{ .after = .fromSeconds(60) });
    try r.expect(created == .created, "create of a new key answered {t}, not created", .{created});
    // A key of another job, and another key of the job, are other records.
    try r.expect(try r.create("s3-other", "order-42", .{ .after = .fromSeconds(60) }) == .created, "create of the same key of another job did not answer created", .{});
    try r.expect(try r.create(job, "order-43", .{ .after = .fromSeconds(60) }) == .created, "create of another key of the job did not answer created", .{});
    const found = try r.fetch(job, "order-42");
    try r.expect(std.mem.eql(u8, found.job, job) and std.mem.eql(u8, found.key, "order-42"), "get of {s}/order-42 gave {s}/{s}", .{ job, found.job, found.key });
    try r.expect(try r.remove(job, "order-42"), "remove of a record that is there returned false", .{});
    try r.expect(try r.get(job, "order-42") == null, "get after remove found the record", .{});
    try r.expect(!try r.remove(job, "order-42"), "remove of a record that is gone returned true", .{});
    _ = try r.fetch("s3-other", "order-42");
    _ = try r.fetch(job, "order-43");
}

pub fn s4(r: *Runner) Error!void {
    const job = "s4-send";
    const request: Store.CreateRequest = .{ .job = job, .key = "order-42", .tenant = "acme", .life = r.newLife(), .plan = "every 60s", .payload = "{\"order_id\":42}", .trace = trace, .run_at = .{ .after = .fromSeconds(60) } };
    try expectCreate(r, &request, .created, "of a new key");
    const start = try r.fetch(job, "order-42");

    // The same revision and state: updated, the revision one more, the
    // rest as it was.
    const asked = try r.updated(start, .{ .pause_requested = true });
    try r.expect(asked.pause_requested, "update of pause_requested did not set it", .{});
    try r.expectSame(start, asked, &.{ "revision", "pause_requested", "updated_at" }, "update of pause_requested");

    // Another revision or state: conflict, with the record as it is now;
    // no record: not_found.
    for ([_]model.State{ .pending, .paused }, [_]u64{ start.revision, asked.revision }) |state, revision| {
        var stale = asked;
        stale.state = state;
        stale.revision = revision;
        const result = try r.update(stale, .{ .plan = "every 30s" });
        switch (result) {
            .conflict => |now| try r.expectSame(asked, now, &.{}, "the record of a conflict"),
            else => return r.fail("update on revision {d} and state {t} of a record of revision {d}, pending, answered {t}, not conflict", .{ revision, state, asked.revision, result }),
        }
    }
    try r.expectSame(asked, try r.fetch(job, "order-42"), &.{}, "an update that answered conflict");
    var missing = asked;
    missing.key = "order-43";
    const none = try r.update(missing, .{ .plan = "every 30s" });
    try r.expect(none == .not_found, "update of a key never created answered {t}, not not_found", .{none});

    // plan, then run_at .after and .at: run_at and scheduled_at, attempt 0.
    const planned = try r.updated(asked, .{ .plan = "cron 30 3 * * *" });
    try r.expect(std.mem.eql(u8, planned.plan, "cron 30 3 * * *"), "update of plan gave \"{s}\"", .{planned.plan});
    const t0 = r.now();
    const later = try r.updated(planned, .{ .run_at = .{ .after = .fromSeconds(7200) } });
    const t1 = r.now();
    try r.expectNear(later.run_at, t0, t1, .fromSeconds(7200), "run_at of an update to .after 2 h");
    try r.expectNear(later.scheduled_at, t0, t1, .fromSeconds(7200), "scheduled_at of an update to .after 2 h");
    try r.expectSame(planned, later, &.{ "revision", "run_at", "scheduled_at", "updated_at" }, "update of run_at");
    const at: Instant = .fromUnixMs(t0.unix_ms - 60_000);
    const due = try r.updated(later, .{ .run_at = .{ .at = at } });
    try r.expect(due.run_at != null and due.run_at.?.unix_ms == at.unix_ms and due.scheduled_at.unix_ms == at.unix_ms, "update to .at {f} gave run_at {?f}", .{ at, due.run_at });

    // Paused, the due record is not claimed; pending again, it is.
    const paused = try r.updated(due, .{ .state = .paused });
    try r.expect(paused.state == .paused and paused.run_at != null, "update to paused left a record {t}, run_at {?f}", .{ paused.state, paused.run_at });
    const none_claimed = try r.claim("s4-worker", &.{job}, &.{}, 5, r.ms(60_000));
    try r.expect(none_claimed.claimed.len == 0, "a claim took a paused record", .{});
    const unpaused = try r.updated(paused, .{ .state = .pending });
    const result = try r.claim("s4-worker", &.{job}, &.{}, 5, r.ms(60_000));
    try r.expect(result.claimed.len == 1, "a claim of a due record, paused and then pending, took {d} records", .{result.claimed.len});
    const claimed = result.claimed[0].record;
    try r.expect(claimed.scheduled_at.unix_ms == unpaused.scheduled_at.unix_ms, "a claim moved scheduled_at", .{});

    // A change of a running record: a new scheduled_at, attempt 0, and
    // still no run_at.
    const moved = try r.updated(claimed, .{ .run_at = .{ .after = .fromSeconds(7200) } });
    try r.expect(moved.state == .running and moved.run_at == null and moved.attempt == 0, "update of the run_at of a running record left it {t}, run_at {?f}, attempt {d}", .{ moved.state, moved.run_at, moved.attempt });
    try r.expect(moved.scheduled_at.unix_ms > claimed.scheduled_at.unix_ms, "update of the run_at of a running record kept its scheduled_at", .{});

    // A failed record reset: pending at once, attempt 0, no finished_at or
    // expires_at, its scheduled_at kept; a claim takes it at once.
    try r.finished(r.finishOf(moved, "s4-worker", .{ .done = .{ .state = .failed, .keep = .{ .keep_for = .fromSeconds(3600) } } }));
    const failed = try r.fetch(job, "order-42");
    const t2 = r.now();
    const reset = try r.updated(failed, .{ .reset = true });
    const t3 = r.now();
    try r.expect(reset.state == .pending and reset.attempt == 0 and reset.finished_at == null and reset.expires_at == null, "reset of a failed record left it {t}, attempt {d}, finished_at {?f}, expires_at {?f}", .{ reset.state, reset.attempt, reset.finished_at, reset.expires_at });
    try r.expectNear(reset.run_at, t2, t3, .zero, "run_at of a reset");
    try r.expect(reset.scheduled_at.unix_ms == failed.scheduled_at.unix_ms, "reset moved scheduled_at from {f} to {f}", .{ failed.scheduled_at, reset.scheduled_at });
    const again = try r.claim("s4-worker", &.{job}, &.{}, 5, r.ms(60_000));
    try r.expect(again.claimed.len == 1 and again.claimed[0].record.scheduled_at.unix_ms == failed.scheduled_at.unix_ms, "a claim right after reset took {d} records, or moved scheduled_at", .{again.claimed.len});
}

pub fn s5(r: *Runner) Error!void {
    // 50 records: 25 of each job, the tenants t0–t2 in turn and none every
    // seventh, every fifth paused.
    const jobs = [_][]const u8{ "s5-a", "s5-b" };
    const tenants = [_][]const u8{ "t0", "t1", "t2" };
    var expected: struct { a: usize = 0, t1: usize = 0, paused: usize = 0, b_t2_pending: usize = 0 } = .{};
    for (0..50) |i| {
        var buffer: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "k{d:0>2}", .{i}) catch unreachable;
        const tenant: ?[]const u8 = if (i % 7 == 0) null else tenants[i % 3];
        const request: Store.CreateRequest = .{ .job = jobs[i % 2], .key = key, .tenant = tenant, .life = r.newLife(), .plan = "", .payload = "{}", .run_at = .{ .after = .fromSeconds(60) } };
        try expectCreate(r, &request, .created, "of a new key");
        const paused = i % 5 == 0;
        if (paused) _ = try r.updated(try r.fetch(jobs[i % 2], key), .{ .state = .paused });
        if (i % 2 == 0) expected.a += 1;
        if (tenant != null and i % 3 == 1) expected.t1 += 1;
        if (paused) expected.paused += 1;
        if (i % 2 == 1 and tenant != null and i % 3 == 2 and !paused) expected.b_t2_pending += 1;
    }

    // Pages of 7: every record once.
    const all = try r.listAll(.{}, 7);
    try r.expect(all.len == 50, "list in pages of 7 gave {d} records of 50", .{all.len});
    const filters = [_]model.ListFilter{ .{ .job = "s5-a" }, .{ .tenant = "t1" }, .{ .state = .paused }, .{ .job = "s5-b", .tenant = "t2", .state = .pending } };
    const counts = [_]usize{ expected.a, expected.t1, expected.paused, expected.b_t2_pending };
    for (filters, counts) |filter, count| {
        const some = try r.listAll(filter, 7);
        try r.expect(some.len == count, "list of job {?s}, tenant {?s}, state {?t} gave {d} records, not {d}", .{ filter.job, filter.tenant, filter.state, some.len, count });
    }
    const one_page = try r.need(r.store().list(r.io, r.ctx(), &.{ .filter = .{ .state = .paused }, .page = .{ .limit = 100 } }, r.call()), "list");
    try r.expect(one_page.records.len == expected.paused and one_page.next == null, "list of the paused records in one page of 100 gave {d} and a next page", .{one_page.records.len});
}

/// 256 bytes of UTF-8, with '/' and Cyrillic.
const long_key = key: {
    var k: []const u8 = "";
    for (0..28) |_| k = k ++ "ключ/";
    break :key k ++ "1234";
};
/// 128 bytes of UTF-8.
const long_tenant = tenant: {
    var t: []const u8 = "";
    for (0..10) |_| t = t ++ "тенант";
    break :tenant t ++ "-1234567";
};
/// 64 bytes: the longest name of a job.
const long_job = job: {
    var j: []const u8 = "s18.";
    for (0..60) |i| j = j ++ &[_]u8{"abcdefghijklmnopqrstuvwxyz0123456789-_."[i % 39]};
    break :job j;
};
/// An instance of 64 bytes of UTF-8, and the 32 hex of its run.
const long_owner = "экземпляр" ++ "экземпляр" ++ "экземпляр" ++ "-123456789" ++ "/0123456789abcdef0123456789abcdef";

pub fn s18(r: *Runner) Error!void {
    comptime std.debug.assert(long_key.len == 256 and long_tenant.len == 128 and long_job.len == 64 and long_owner.len == 97);
    // A payload of 64 KiB.
    const payload = try r.scratch.alloc(u8, 64 * 1024);
    @memset(payload, 'x');
    @memcpy(payload[0..9], "{\"note\":\"");
    @memcpy(payload[payload.len - 2 ..], "\"}");

    const keys = [_][]const u8{ long_key, "$set", "$$NOW", "a.b", "{\"$gt\":1}", "" };
    const tenants = [_]?[]const u8{ long_tenant, "$where", null, "$where", "a.b", null };
    var requests: [keys.len]Store.CreateRequest = undefined;
    for (&requests, keys, tenants, 0..) |*request, key, tenant, i| {
        request.* = .{ .job = long_job, .key = key, .tenant = tenant, .life = r.newLife(), .plan = if (i == 0) "cron 0 3 * * *" else "", .payload = if (i == 0) payload else "{\"$set\":{\"a.b\":1}}", .trace = if (i % 2 == 0) trace else null, .run_at = .{ .after = .zero } };
        try expectCreate(r, request, .created, "of a key at the limits");
        try expectFresh(r, try r.fetch(long_job, key), request);
    }
    // Listed byte for byte, by the job and by the tenants.
    const all = try r.listAll(.{ .job = long_job }, 2);
    try r.expect(all.len == keys.len, "list of the job of 64 bytes gave {d} records, not {d}", .{ all.len, keys.len });
    for (all) |rec| {
        const i = for (keys, 0..) |key, k| {
            if (std.mem.eql(u8, rec.key, key)) break k;
        } else return r.fail("list gave a key that was never created, of {d} bytes", .{rec.key.len});
        try expectFresh(r, rec, &requests[i]);
    }
    for ([_][]const u8{ "$where", long_tenant }, [_]usize{ 2, 1 }) |tenant, count| {
        const some = try r.listAll(.{ .tenant = tenant }, 7);
        try r.expect(some.len == count, "list of the tenant of {d} bytes gave {d} records, not {d}", .{ tenant.len, some.len, count });
    }

    // Claimed by an owner of 97 bytes, and finished with rows that come
    // back byte for byte.
    const result = try r.claim(long_owner, &.{long_job}, &.{}, 10, r.ms(60_000));
    try r.expect(result.claimed.len == keys.len, "a claim of {d} due records took {d}", .{ keys.len, result.claimed.len });
    for (result.claimed) |c| {
        var request = r.finishOf(c.record, long_owner, .{ .done = .{ .state = .failed, .keep = .forever } });
        request.last = Runner.lastOf(c.record, .failed, "{\"$gt\":1}");
        const rows = [_]model.Run{Runner.rowOf(c.record, .failed, "$where", long_owner)};
        request.history = .{ .runs = &rows, .keep = .forever };
        try r.finished(request);
    }
    for (keys, tenants) |key, tenant| {
        const rows = try r.historyAll(.{ .job = long_job, .key = key }, 7);
        try r.expect(rows.len == 1, "history of a key at the limits gave {d} rows, not 1", .{rows.len});
        const row = rows[0];
        const same_tenant = if (tenant) |t| std.mem.eql(u8, row.tenant orelse "", t) else row.tenant == null;
        try r.expect(same_tenant and std.mem.eql(u8, row.instance, long_owner) and std.mem.eql(u8, row.error_name orelse "", "$where"), "a row of a key at the limits came back with another tenant, instance or error_name", .{});
        const rec = try r.fetch(long_job, key);
        try r.expect(rec.last != null and std.mem.eql(u8, rec.last.?.error_name orelse "", "{\"$gt\":1}"), "a record at the limits came back with another last run", .{});
    }
    const by_tenant = try r.historyAll(.{ .tenant = "$where" }, 7);
    try r.expect(by_tenant.len == 2, "history of the tenant $where gave {d} rows, not 2", .{by_tenant.len});
}

/// Fails unless each slice of `rec` lies in `fence`.
fn expectOwned(r: *Runner, fence: *const Runner.Fence, rec: Record, comptime what: []const u8) Error!void {
    const texts = [_]?[]const u8{ rec.job, rec.key, rec.tenant, rec.plan, rec.payload, rec.owner, rec.trace, if (rec.last) |l| l.error_name else null };
    for (texts) |text| {
        try r.expect(fence.owns(text orelse ""), "a string of the record of " ++ what ++ " is not in options.allocator", .{});
    }
}

pub fn s19(r: *Runner) Error!void {
    const job = "s19-send";
    const owner = "s19-worker";
    var fences: [9]Runner.Fence = undefined;
    for (&fences) |*f| f.* = .init(r.gpa);
    defer for (&fences) |*f| f.deinit();
    // The strings of the requests live here; after each call they are
    // overwritten, so a store that kept one reads 0x55 later.
    var borrowed: [64]u8 = undefined;
    const lend = struct {
        fn text(buffer: []u8, at: usize, s: []const u8) []const u8 {
            @memcpy(buffer[at..][0..s.len], s);
            return buffer[at..][0..s.len];
        }
    }.text;

    const create: Store.CreateRequest = .{ .job = lend(&borrowed, 0, job), .key = lend(&borrowed, 8, "k1"), .tenant = lend(&borrowed, 10, "acme"), .life = r.newLife(), .plan = lend(&borrowed, 14, "every 9s"), .payload = lend(&borrowed, 22, "{\"n\":1}"), .trace = lend(&borrowed, 29, trace[0..20]), .run_at = .{ .after = .zero } };
    _ = try r.need(r.store().create(r.io, r.ctx(), &create, .{ .allocator = fences[0].allocator() }), "create");
    fences[0].close();
    @memset(&borrowed, 0x55);
    const got = (try r.need(r.store().get(r.io, r.ctx(), &.{ .job = job, .key = "k1" }, .{ .allocator = fences[1].allocator() }), "get")) orelse
        return r.fail("get after create found no record", .{});
    fences[1].close();
    try expectOwned(r, &fences[1], got, "get");
    const kept = try r.fetch(job, "k1");
    try r.expect(std.mem.eql(u8, kept.job, job) and std.mem.eql(u8, kept.key, "k1") and std.mem.eql(u8, kept.tenant orelse "", "acme") and
        std.mem.eql(u8, kept.plan, "every 9s") and std.mem.eql(u8, kept.payload, "{\"n\":1}") and std.mem.eql(u8, kept.trace orelse "", trace[0..20]), "the record changed with the memory of the request after create returned", .{});

    // A conflict gives a record; a claim records and took_over; a finish
    // that answers changed, a record: all in the allocator of the call.
    const update: Store.UpdateRequest = .{ .ref = .{ .job = job, .key = lend(&borrowed, 0, "k1") }, .expect = .{ .revision = kept.revision +% 1, .state = .pending }, .set = .{ .plan = lend(&borrowed, 2, "every 8s") }, .tag = r.newTag() };
    const conflict = try r.need(r.store().update(r.io, r.ctx(), &update, .{ .allocator = fences[2].allocator() }), "update");
    fences[2].close();
    @memset(&borrowed, 0x55);
    switch (conflict) {
        .conflict => |rec| try expectOwned(r, &fences[2], rec, "a conflict"),
        else => return r.fail("update on another revision answered {t}, not conflict", .{conflict}),
    }
    const first = try r.claim(lend(&borrowed, 0, owner), &.{job}, &.{}, 1, r.ms(1000));
    @memset(&borrowed, 0x55);
    try r.expect(first.claimed.len == 1, "a claim of a due record took {d}", .{first.claimed.len});
    const abandoned = first.claimed[0].record;
    try r.waitPast(abandoned.lease_until.?);
    const took = for (0..100) |_| {
        const result = try r.need(r.store().claim(r.io, r.ctx(), &.{ .owner = owner, .any_key = &.{job}, .keyed_only = &.{}, .max = 1, .lease = r.ms(60_000), .tag = r.newTag() }, .{ .allocator = fences[3].allocator() }), "claim");
        if (result.claimed.len == 1) break result;
        try r.sleep(r.ms(50));
    } else return r.fail("a claim never took over a record whose lease expired", .{});
    // Copied out first: closed, the fence overwrites what it gave.
    const took_record = took.claimed[0].record;
    const took_over = took.claimed[0].took_over orelse return r.fail("a claim of an expired lease gave no took_over", .{});
    try r.expect(std.mem.eql(u8, took_over.owner, owner), "took_over names the owner \"{s}\", not \"{s}\"", .{ took_over.owner, owner });
    fences[3].close();
    try r.expect(fences[3].owns(std.mem.sliceAsBytes(took.claimed)) and fences[3].owns(took_over.owner), "the records of a claim or its took_over are not in options.allocator", .{});
    try expectOwned(r, &fences[3], took_record, "a claim");
    const run = try r.fetch(job, "k1");
    const moved = try r.updated(run, .{ .pause_requested = true });
    var finish = r.finishOf(run, lend(&borrowed, 0, owner), .{ .done = .{ .state = .succeeded, .keep = .forever } });
    const rows = [_]model.Run{ Runner.rowOf(abandoned, .abandoned, null, owner), Runner.rowOf(run, .succeeded, lend(&borrowed, 10, "NoteOfRow"), lend(&borrowed, 19, owner)) };
    finish.history = .{ .runs = &rows, .keep = .forever };
    const changed = try r.need(r.store().finish(r.io, r.ctx(), &finish, .{ .allocator = fences[4].allocator() }), "finish");
    fences[4].close();
    @memset(&borrowed, 0x55);
    switch (changed) {
        .changed => |rec| try expectOwned(r, &fences[4], rec, "a finish that answered changed"),
        else => return r.fail("finish on an old revision answered {t}, not changed", .{changed}),
    }
    try r.finished(r.finishOf(moved, owner, .{ .done = .{ .state = .succeeded, .keep = .forever } }));
    const renew = try r.need(r.store().renew(r.io, r.ctx(), &.{ .ref = Runner.refOf(run), .life = run.life, .owner = owner, .fence = run.fence, .lease = r.ms(1000) }, .{ .allocator = fences[5].allocator() }), "renew");
    fences[5].close();
    try r.expect(renew != .renewed, "renew of a finished claim answered renewed", .{});

    // Pages of list and history, and their next.
    _ = try r.create(job, "k2", .{ .after = .fromSeconds(60) });
    const list = try r.need(r.store().list(r.io, r.ctx(), &.{ .filter = .{ .job = job }, .page = .{ .limit = 1 } }, .{ .allocator = fences[6].allocator() }), "list");
    try r.expect(list.records.len == 1 and list.next != null, "list of 2 records a page of 1 gave {d} and no next", .{list.records.len});
    const listed = list.records[0];
    fences[6].close();
    try r.expect(fences[6].owns(std.mem.sliceAsBytes(list.records)) and fences[6].owns(list.next.?), "the page of list is not in options.allocator", .{});
    try expectOwned(r, &fences[6], listed, "list");
    const history = try r.need(r.store().history(r.io, r.ctx(), &.{ .filter = .{ .job = job }, .page = .{ .limit = 1 } }, .{ .allocator = fences[7].allocator() }), "history");
    try r.expect(history.runs.len == 1 and history.next != null, "history of 2 rows a page of 1 gave {d} and no next", .{history.runs.len});
    const row = history.runs[0];
    fences[7].close();
    try r.expect(fences[7].owns(std.mem.sliceAsBytes(history.runs)) and fences[7].owns(history.next.?), "the page of history is not in options.allocator", .{});
    for ([_]?[]const u8{ row.job, row.key, row.tenant, row.error_name, row.instance }) |text| {
        try r.expect(fences[7].owns(text orelse ""), "a string of a row of history is not in options.allocator", .{});
    }
    const removed = try r.need(r.store().remove(r.io, r.ctx(), &.{ .job = job, .key = "k2" }, .{ .allocator = fences[8].allocator() }), "remove");
    fences[8].close();
    try r.expect(removed, "remove of a record that is there returned false", .{});

    // The store keeps copies: the rows read back right, after the memory of
    // the finish that wrote them was overwritten.
    const kept_rows = try r.historyAll(.{ .job = job, .outcome = .succeeded }, 7);
    try r.expect(kept_rows.len == 1 and std.mem.eql(u8, kept_rows[0].error_name orelse "", "NoteOfRow") and std.mem.eql(u8, kept_rows[0].instance, owner), "the row changed with the memory of the finish after it returned", .{});
    for (&fences, 0..) |*f, i| {
        try r.expect(f.lateUses() == 0, "the store used the options.allocator of call {d} {d} time(s) after it returned", .{ i, f.lateUses() });
    }
}
