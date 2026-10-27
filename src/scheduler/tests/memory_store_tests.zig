//! Tests of scheduler.MemoryStore: records and changes, claims, leases,
//! finishes, the history and what the store keeps.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const scheduler = @import("../root.zig");
const Store = scheduler.Store;
const Instant = scheduler.Instant;
const Record = scheduler.Record;
const MemoryStore = scheduler.MemoryStore;
const Table = @import("../memory/Table.zig");

const io = testing.io;

/// The one record of a claim.
fn one(result: Store.ClaimResult) !Record {
    if (result.claimed.len != 1) return error.TestUnexpectedResult;
    return result.claimed[0].record;
}

/// A store and an arena for the results of its calls.
const Fixture = struct {
    memory: MemoryStore,
    arena: std.heap.ArenaAllocator,
    /// The first byte of the life of the next `running` record.
    lives: u8 = 100,

    fn init(limits: MemoryStore.Options) Fixture {
        return .{ .memory = .init(testing.allocator, io, limits), .arena = .init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.memory.deinit();
        f.arena.deinit();
    }

    fn store(f: *Fixture) Store {
        return f.memory.store();
    }

    fn options(f: *Fixture) Store.CallOptions {
        return .{ .allocator = f.arena.allocator() };
    }

    fn now(f: *Fixture) Instant {
        return f.store().now(io);
    }

    /// A one-shot record of `job` and `key` with the payload `{}`, due at
    /// `run_at`; its life is the first byte `life` and zeros.
    fn create(f: *Fixture, job: []const u8, key: []const u8, run_at: Store.Moment, life: u8) !Store.CreateResult {
        var bytes: scheduler.Life = @splat(0);
        bytes[0] = life;
        return f.store().create(io, .root, &.{ .job = job, .key = key, .life = bytes, .plan = "", .payload = "{}", .run_at = run_at }, f.options());
    }

    fn get(f: *Fixture, job: []const u8, key: []const u8) !Record {
        return (try f.store().get(io, .root, &.{ .job = job, .key = key }, f.options())) orelse error.TestUnexpectedResult;
    }

    /// An update on `revision` and `state` of the record of `job` and `key`,
    /// on the life it has now.
    fn update(f: *Fixture, job: []const u8, key: []const u8, revision: u64, state: scheduler.State, set: Store.Patch) !Store.UpdateResult {
        const ref: scheduler.Ref = .{ .job = job, .key = key };
        const life: scheduler.Life = if (try f.store().get(io, .root, &ref, f.options())) |r| r.life else @splat(0);
        return f.store().update(io, .root, &.{ .ref = ref, .expect = .{ .life = life, .revision = revision, .state = state }, .set = set, .tag = @splat(9) }, f.options());
    }

    fn claim(f: *Fixture, owner: []const u8, any_key: []const []const u8, keyed_only: []const []const u8, max: u32, lease: Io.Duration) !Store.ClaimResult {
        return f.store().claim(io, .root, &.{ .owner = owner, .any_key = any_key, .keyed_only = keyed_only, .max = max, .lease = lease, .tag = @splat(3) }, f.options());
    }

    /// A record of `job` and `key` with a life of its own, due a second ago
    /// and claimed by `owner` with a lease of `lease`: the record of the
    /// claim.
    fn running(f: *Fixture, job: []const u8, key: []const u8, owner: []const u8, lease: Io.Duration) !Record {
        f.lives += 1;
        _ = try f.create(job, key, .{ .after = .fromSeconds(-1) }, f.lives);
        return one(try f.claim(owner, &.{}, &.{job}, 1, lease));
    }

    /// The finish of the claim of `r` by `owner`, with its fence and
    /// revision, and rows kept always.
    fn finish(f: *Fixture, r: Record, owner: []const u8, next: Store.Next, last: ?scheduler.LastRun, runs: []const scheduler.Run) !Store.FinishResult {
        return f.store().finish(io, .root, &.{
            .ref = .{ .job = r.job, .key = r.key },
            .life = r.life,
            .owner = owner,
            .fence = r.fence,
            .revision = r.revision,
            .tag = @splat(4),
            .next = next,
            .last = last,
            .history = .{ .runs = runs, .keep = .forever },
        }, f.options());
    }

    fn history(f: *Fixture, filter: scheduler.HistoryFilter) ![]const scheduler.Run {
        return (try f.store().history(io, .root, &.{ .filter = filter, .page = .{} }, f.options())).runs;
    }

    /// Until the store's clock is past `at`.
    fn waitPast(f: *Fixture, at: Instant) !void {
        while (f.now().unix_ms <= at.unix_ms) try io.sleep(.fromMilliseconds(5), .awake);
    }

    /// The indexes of the store agree with its records.
    fn check(f: *Fixture) !void {
        f.memory.mutex.lockUncancelable(io);
        defer f.memory.mutex.unlock(io);
        if (f.memory.table.check()) |problem| {
            std.debug.print("MemoryStore: {s}\n", .{problem});
            return error.TestUnexpectedResult;
        }
    }
};

/// A row of the history of `r`'s claim.
fn rowOf(r: Record, outcome: scheduler.RunOutcome, error_name: ?[]const u8, instance: []const u8) scheduler.Run {
    return .{
        .job = r.job,
        .key = r.key,
        .tenant = r.tenant,
        .life = r.life,
        .fence = r.fence,
        .attempt = r.attempt,
        .scheduled_at = r.scheduled_at,
        .started_at = r.claimed_at orelse .fromUnixMs(0),
        .finished_at = .fromUnixMs(0),
        .outcome = outcome,
        .error_name = error_name,
        .instance = instance,
        .expires_at = null,
    };
}

fn lastOf(r: Record, outcome: scheduler.RunOutcome, error_name: ?[]const u8) scheduler.LastRun {
    return .{ .outcome = outcome, .error_name = error_name, .attempt = r.attempt, .started_at = r.claimed_at orelse .fromUnixMs(0), .finished_at = .fromUnixMs(0) };
}

/// Whether `x` lies in `[low, high]` milliseconds.
fn expectWithin(x: Instant, low: Instant, high: Instant) !void {
    if (x.unix_ms < low.unix_ms or x.unix_ms > high.unix_ms) {
        std.debug.print("{d} is not in [{d}, {d}]\n", .{ x.unix_ms, low.unix_ms, high.unix_ms });
        return error.TestUnexpectedResult;
    }
}

test "create makes a pending record of a new life" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const life: scheduler.Life = @splat(5);
    const before = f.now();
    const created = try f.store().create(io, .root, &.{
        .job = "send-invoice",
        .key = "order-42",
        .tenant = "acme",
        .life = life,
        .plan = "",
        .payload = "{\"order_id\":42}",
        .trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        .run_at = .{ .after = .fromSeconds(2) },
    }, f.options());
    const after = f.now();
    try testing.expectEqual(Store.CreateResult.created, created);

    const r = try f.get("send-invoice", "order-42");
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqualStrings("send-invoice", r.job);
    try testing.expectEqualStrings("order-42", r.key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), r.tenant);
    try testing.expectEqualStrings("{\"order_id\":42}", r.payload);
    try testing.expectEqualStrings("", r.plan);
    try testing.expectEqualDeep(@as(?[]const u8, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"), r.trace);
    try testing.expectEqualSlices(u8, &life, &r.life);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(@as(u64, 0), r.fence);
    try testing.expectEqual(@as(u64, 0), r.revision);
    try testing.expect(!r.pause_requested);
    try testing.expectEqual(@as(?[]const u8, null), r.owner);
    try testing.expectEqual(@as(?Instant, null), r.claimed_at);
    try testing.expectEqual(@as(?Instant, null), r.lease_until);
    try testing.expectEqual(@as(?scheduler.LastRun, null), r.last);
    try testing.expectEqual(@as(?Instant, null), r.finished_at);
    try testing.expectEqual(@as(?Instant, null), r.expires_at);
    try testing.expectEqual(@as(?Instant, null), r.unreadable_since);
    // By the store's clock: .after(2 s) is its now and 2 s.
    try expectWithin(r.created_at, before, after);
    try testing.expectEqual(r.created_at, r.updated_at);
    try testing.expectEqual(@as(?Instant, r.created_at.add(.fromSeconds(2))), r.run_at);
    try testing.expectEqual(r.run_at.?, r.scheduled_at);

    // .at is the moment as it is.
    try testing.expectEqual(Store.CreateResult.created, try f.create("send-invoice", "order-43", .{ .at = .fromUnixMs(1_000_123) }, 1));
    const at = try f.get("send-invoice", "order-43");
    try testing.expectEqual(@as(?Instant, .fromUnixMs(1_000_123)), at.run_at);
    try testing.expectEqual(Instant.fromUnixMs(1_000_123), at.scheduled_at);
}

test "create of a live key is existing and changes nothing" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    try testing.expectEqual(Store.CreateResult.created, try f.create("send-invoice", "order-42", .{ .at = .fromUnixMs(5_000) }, 1));
    const first = try f.get("send-invoice", "order-42");
    try testing.expectEqual(Store.CreateResult.existing, try f.store().create(io, .root, &.{
        .job = "send-invoice",
        .key = "order-42",
        .tenant = "other",
        .life = @splat(2),
        .plan = "every 60s",
        .payload = "{\"x\":1}",
        .run_at = .{ .after = .zero },
    }, f.options()));
    try testing.expectEqualDeep(first, try f.get("send-invoice", "order-42"));
    // A paused record is live too.
    _ = try f.update("send-invoice", "order-42", 0, .pending, .{ .state = .paused });
    try testing.expectEqual(Store.CreateResult.existing, try f.create("send-invoice", "order-42", .{ .after = .zero }, 3));
    try testing.expectEqual(@as(u8, 1), (try f.get("send-invoice", "order-42")).life[0]);
}

test "create refuses what breaks the rules of names" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    const life: scheduler.Life = @splat(1);
    const bad = [_]Store.CreateRequest{
        .{ .job = "Send", .key = "k", .life = life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } },
        .{ .job = "send", .key = "a\x00b", .life = life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } },
        .{ .job = "send", .key = "k", .tenant = "", .life = life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } },
    };
    for (bad) |request| {
        try testing.expectError(error.InvalidArgument, f.store().create(io, .root, &request, .{ .allocator = f.arena.allocator(), .diagnostics = &d }));
        try testing.expect(d.message().len > 0);
    }
    // The record of a declared job has the key "".
    try testing.expectEqual(Store.CreateResult.created, try f.create("nightly-cleanup", "", .{ .after = .zero }, 1));
    const page = try f.store().list(io, .root, &.{ .filter = .{}, .page = .{} }, f.options());
    try testing.expectEqual(@as(usize, 1), page.records.len);
}

test "update applies on life, revision and state and raises revision" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    _ = try f.create("send-invoice", "order-42", .{ .at = .fromUnixMs(5_000) }, 1);

    const before = f.now();
    const updated = try f.update("send-invoice", "order-42", 0, .pending, .{ .plan = "every 60s", .pause_requested = true });
    try testing.expect(updated == .updated and updated.updated == 1);
    const r = try f.get("send-invoice", "order-42");
    try testing.expectEqual(@as(u64, 1), r.revision);
    try testing.expectEqualStrings("every 60s", r.plan);
    try testing.expect(r.pause_requested);
    try expectWithin(r.updated_at, before, f.now());
    // Fields outside `set` stay.
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(?Instant, .fromUnixMs(5_000)), r.run_at);
    try testing.expectEqualStrings("{}", r.payload);
    try testing.expectEqual(@as(u8, 1), r.life[0]);

    // Another revision or another state: the record as it is.
    const stale = try f.update("send-invoice", "order-42", 0, .pending, .{ .state = .paused });
    try testing.expect(stale == .conflict and stale.conflict.revision == 1 and stale.conflict.state == .pending);
    const wrong_state = try f.update("send-invoice", "order-42", 1, .paused, .{ .state = .pending });
    try testing.expect(wrong_state == .conflict and wrong_state.conflict.revision == 1);
    try testing.expect(try f.update("send-invoice", "order-41", 0, .pending, .{ .state = .paused }) == .not_found);
    // Its revision and state, on another life: a conflict too.
    var other: scheduler.Life = @splat(0);
    other[0] = 2;
    const reborn = try f.store().update(io, .root, &.{ .ref = .{ .job = "send-invoice", .key = "order-42" }, .expect = .{ .life = other, .revision = 1, .state = .pending }, .set = .{ .state = .paused }, .tag = @splat(9) }, f.options());
    try testing.expect(reborn == .conflict and reborn.conflict.life[0] == 1 and reborn.conflict.state == .pending);

    // .after by the store's clock; run_at and scheduled_at move, attempt is 0.
    const moved_from = f.now();
    _ = try f.update("send-invoice", "order-42", 1, .pending, .{ .run_at = .{ .after = .fromSeconds(5) } });
    const moved = try f.get("send-invoice", "order-42");
    try expectWithin(moved.run_at orelse return error.TestUnexpectedResult, moved_from.add(.fromSeconds(5)), f.now().add(.fromSeconds(5)));
    try testing.expectEqual(moved.run_at.?, moved.scheduled_at);
    try testing.expectEqual(@as(u32, 0), moved.attempt);

    // A paused record keeps run_at, and gives it back to pending.
    _ = try f.update("send-invoice", "order-42", 2, .pending, .{ .state = .paused });
    const paused = try f.get("send-invoice", "order-42");
    try testing.expectEqual(scheduler.State.paused, paused.state);
    try testing.expectEqual(moved.run_at, paused.run_at);
    _ = try f.update("send-invoice", "order-42", 3, .paused, .{ .state = .pending });
    try testing.expectEqual(moved.run_at, (try f.get("send-invoice", "order-42")).run_at);

    // A state other than pending and paused is not the client's.
    var d: scheduler.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, f.store().update(io, .root, &.{
        .ref = .{ .job = "send-invoice", .key = "order-42" },
        .expect = .{ .life = paused.life, .revision = 4, .state = .pending },
        .set = .{ .state = .succeeded },
        .tag = @splat(0),
    }, .{ .allocator = f.arena.allocator(), .diagnostics = &d }));
    try testing.expectEqual(@as(u64, 4), (try f.get("send-invoice", "order-42")).revision);
}

test "remove says whether the record was there" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    _ = try f.create("send-invoice", "order-42", .{ .after = .zero }, 1);
    const ref: scheduler.Ref = .{ .job = "send-invoice", .key = "order-42" };
    try testing.expect(try f.store().remove(io, .root, &ref, f.options()));
    try testing.expectEqual(@as(?Record, null), try f.store().get(io, .root, &ref, f.options()));
    try testing.expect(!try f.store().remove(io, .root, &ref, f.options()));
    // The key is free again: a new life.
    try testing.expectEqual(Store.CreateResult.created, try f.create("send-invoice", "order-42", .{ .after = .zero }, 2));
    try testing.expectEqual(@as(u8, 2), (try f.get("send-invoice", "order-42")).life[0]);
}

test "list filters by job, tenant and state and pages by (job, key)" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    // 50 records: 25 of each job, the tenants t0–t2 in turn, every fifth paused.
    const jobs = [_][]const u8{ "send-invoice", "send" };
    const tenants = [_][]const u8{ "t0", "t1", "t2" };
    for (0..50) |i| {
        var key: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&key, "k{d:0>2}", .{i});
        _ = try f.store().create(io, .root, &.{
            .job = jobs[i % 2],
            .key = k,
            .tenant = tenants[i % 3],
            .life = @splat(@intCast(i)),
            .plan = "",
            .payload = "{}",
            .run_at = .{ .after = .fromSeconds(60) },
        }, f.options());
        if (i % 5 == 0) _ = try f.update(jobs[i % 2], k, 0, .pending, .{ .state = .paused });
    }

    // Pages of 7: every record once, in the order (job, key); "send" sorts
    // before "send-invoice".
    var seen: [50]bool = @splat(false);
    var previous: ?[2][]const u8 = null;
    var after: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        const page = try f.store().list(io, .root, &.{ .filter = .{}, .page = .{ .after = after, .limit = 7 } }, f.options());
        try testing.expect(page.records.len <= 7);
        for (page.records) |r| {
            const i = try std.fmt.parseInt(usize, r.key[1..], 10);
            try testing.expect(!seen[i]);
            seen[i] = true;
            try testing.expectEqualStrings(jobs[i % 2], r.job);
            if (previous) |p| {
                const order = std.mem.order(u8, p[0], r.job);
                try testing.expect(order == .lt or (order == .eq and std.mem.order(u8, p[1], r.key) == .lt));
            }
            previous = .{ r.job, r.key };
        }
        after = page.next orelse break;
    }
    try testing.expectEqualSlices(bool, &@as([50]bool, @splat(true)), &seen);
    try testing.expect(pages >= 7);

    // Filters.
    var count: usize = 0;
    after = null;
    while (true) {
        const page = try f.store().list(io, .root, &.{ .filter = .{ .job = "send", .tenant = "t1", .state = .pending }, .page = .{ .after = after, .limit = 3 } }, f.options());
        for (page.records) |r| {
            try testing.expectEqualStrings("send", r.job);
            try testing.expectEqualDeep(@as(?[]const u8, "t1"), r.tenant);
            try testing.expectEqual(scheduler.State.pending, r.state);
            count += 1;
        }
        after = page.next orelse break;
    }
    // Odd i with i % 3 == 1 and i % 5 != 0: 1, 7, 13, 19, 31, 37, 43, 49.
    try testing.expectEqual(@as(usize, 8), count);
    const paused = try f.store().list(io, .root, &.{ .filter = .{ .state = .paused }, .page = .{} }, f.options());
    try testing.expectEqual(@as(usize, 10), paused.records.len);
    try testing.expectEqual(@as(?[]const u8, null), paused.next);

    try testing.expectError(error.InvalidArgument, f.store().list(io, .root, &.{ .filter = .{}, .page = .{ .after = "no continuation" } }, f.options()));
    try testing.expectError(error.InvalidArgument, f.store().list(io, .root, &.{ .filter = .{}, .page = .{ .limit = 0 } }, f.options()));
}

test "a deadline under 1 ms and a cancelled token change nothing" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    const options: Store.CallOptions = .{ .allocator = f.arena.allocator(), .diagnostics = &d };
    const create: Store.CreateRequest = .{ .job = "send-invoice", .key = "order-42", .life = @splat(1), .plan = "", .payload = "{}", .run_at = .{ .after = .zero } };
    const ref: scheduler.Ref = .{ .job = "send-invoice", .key = "order-42" };

    const short = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromMicroseconds(500)));
    try testing.expectError(error.DeadlineExceeded, f.store().create(io, short, &create, options));
    try testing.expect(d.message().len > 0);
    const past = core.Context.root.withDeadline(.at(.fromNanoseconds(0)));
    try testing.expectError(error.DeadlineExceeded, f.store().create(io, past, &create, options));
    var token: core.CancellationToken = .init;
    token.cancel();
    const cancelled = core.Context.root.withCancellation(&token);
    try testing.expectError(error.Cancelled, f.store().create(io, cancelled, &create, options));
    try testing.expectEqual(@as(?Record, null), try f.store().get(io, .root, &ref, options));

    // On a record that is there: no change, no removal.
    _ = try f.store().create(io, .root, &create, options);
    const update: Store.UpdateRequest = .{ .ref = ref, .expect = .{ .life = @splat(1), .revision = 0, .state = .pending }, .set = .{ .state = .paused }, .tag = @splat(0) };
    try testing.expectError(error.DeadlineExceeded, f.store().update(io, past, &update, options));
    try testing.expectError(error.Cancelled, f.store().update(io, cancelled, &update, options));
    try testing.expectError(error.Cancelled, f.store().remove(io, cancelled, &ref, options));
    try testing.expectError(error.DeadlineExceeded, f.store().get(io, past, &ref, options));
    const r = try f.get("send-invoice", "order-42");
    try testing.expectEqual(@as(u64, 0), r.revision);
    try testing.expectEqual(scheduler.State.pending, r.state);
    // A deadline 10 s away passes.
    const fine = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(10)));
    try testing.expect(try f.store().remove(io, fine, &ref, options));
}

test "create over a finished record replaces it with a new life" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("send-invoice", "order-42", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r, "w1", .{ .done = .{ .state = .failed, .keep = .forever } }, lastOf(r, .failed, "Declined"), &.{}) == .done);
    try testing.expectEqual(Store.CreateResult.replaced, try f.create("send-invoice", "order-42", .{ .after = .zero }, 2));
    const fresh = try f.get("send-invoice", "order-42");
    try testing.expectEqual(scheduler.State.pending, fresh.state);
    try testing.expectEqual(@as(u8, 2), fresh.life[0]);
    try testing.expectEqual(@as(u32, 0), fresh.attempt);
    try testing.expectEqual(@as(u64, 0), fresh.fence);
    try testing.expectEqual(@as(?scheduler.LastRun, null), fresh.last);
    try testing.expectEqual(@as(?Instant, null), fresh.finished_at);
    try f.check();
}

test "reset gives a failed record back at once with its scheduled_at" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("send-invoice", "order-42", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r, "w1", .{ .done = .{ .state = .failed, .keep = .{ .keep_for = .fromSeconds(3600) } } }, lastOf(r, .failed, "Declined"), &.{}) == .done);
    const failed = try f.get("send-invoice", "order-42");
    try testing.expect(failed.expires_at != null and failed.finished_at != null);
    const before = f.now();
    const updated = try f.update("send-invoice", "order-42", failed.revision, .failed, .{ .reset = true });
    try testing.expect(updated == .updated);
    const back = try f.get("send-invoice", "order-42");
    try testing.expectEqual(scheduler.State.pending, back.state);
    try expectWithin(back.run_at orelse return error.TestUnexpectedResult, before, f.now());
    try testing.expectEqual(r.scheduled_at, back.scheduled_at);
    try testing.expectEqual(@as(u32, 0), back.attempt);
    try testing.expectEqual(@as(?Instant, null), back.unreadable_since);
    try testing.expectEqual(@as(?Instant, null), back.expires_at);
    try testing.expectEqual(@as(?Instant, null), back.finished_at);
    // Due now: the next claim takes it.
    try testing.expectEqual(@as(usize, 1), (try f.claim("w2", &.{}, &.{"send-invoice"}, 5, .fromSeconds(60))).claimed.len);
    try f.check();
}

test "claim takes due records of the listed jobs, the oldest first, at most max" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const now = f.now();
    _ = try f.create("a", "k1", .{ .at = now.add(.fromMilliseconds(-3000)) }, 1);
    _ = try f.create("b", "k3", .{ .at = now.add(.fromMilliseconds(-1000)) }, 1);
    _ = try f.create("a", "k2", .{ .at = now.add(.fromMilliseconds(-2000)) }, 1);
    _ = try f.create("a", "k4", .{ .at = now.add(.fromSeconds(60)) }, 1);
    _ = try f.create("c", "k5", .{ .at = now.add(.fromMilliseconds(-5000)) }, 1);

    const first = try f.claim("w1", &.{}, &.{ "a", "b" }, 2, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 2), first.claimed.len);
    for (first.claimed, [_][]const u8{ "k1", "k2" }, [_]i64{ -3000, -2000 }) |c, key, due| {
        const r = c.record;
        try testing.expectEqualStrings(key, r.key);
        try testing.expectEqual(scheduler.State.running, r.state);
        try testing.expectEqualDeep(@as(?[]const u8, "w1"), r.owner);
        try testing.expectEqual(@as(u32, 1), r.attempt);
        try testing.expectEqual(@as(u64, 1), r.fence);
        try testing.expectEqual(@as(u64, 0), r.revision);
        try testing.expectEqual(@as(?Instant, null), r.run_at);
        const claimed_at = r.claimed_at orelse return error.TestUnexpectedResult;
        try testing.expect(claimed_at.unix_ms >= now.add(.fromMilliseconds(due)).unix_ms);
        try testing.expectEqual(@as(?Instant, claimed_at.add(.fromSeconds(60))), r.lease_until);
        try testing.expectEqual(@as(?Store.TookOver, null), c.took_over);
    }
    const second = try f.claim("w1", &.{}, &.{ "a", "b" }, 5, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 1), second.claimed.len);
    try testing.expectEqualStrings("k3", second.claimed[0].record.key);
    // The job of no list is never taken.
    try testing.expectEqual(scheduler.State.pending, (try f.get("c", "k5")).state);
    try testing.expectError(error.InvalidArgument, f.claim("w1", &.{}, &.{"a"}, 0, .fromSeconds(60)));
    try f.check();
}

test "claim never takes paused, finished, leased or future records" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    _ = try f.create("a", "paused", .{ .after = .fromSeconds(-1) }, 1);
    _ = try f.update("a", "paused", 0, .pending, .{ .state = .paused });
    for ([_][]const u8{ "succeeded", "failed" }, [_]scheduler.State{ .succeeded, .failed }) |key, state| {
        const r = try f.running("a", key, "w1", .fromSeconds(60));
        _ = try f.finish(r, "w1", .{ .done = .{ .state = state, .keep = .forever } }, null, &.{});
    }
    _ = try f.running("a", "leased", "w1", .fromSeconds(60));
    _ = try f.create("a", "future", .{ .after = .fromSeconds(60) }, 1);
    for (0..3) |_| {
        const result = try f.claim("w2", &.{"a"}, &.{}, 10, .fromSeconds(60));
        try testing.expectEqual(@as(usize, 0), result.claimed.len);
    }
    for ([_][]const u8{ "paused", "succeeded", "failed", "future" }, [_]u64{ 0, 1, 1, 0 }) |key, fence| {
        try testing.expectEqual(fence, (try f.get("a", key)).fence);
    }
    try testing.expectEqualDeep(@as(?[]const u8, "w1"), (try f.get("a", "leased")).owner);
    try f.check();
}

test "an expired lease is taken over: attempt and fence grow, took_over names the claim, also after a move" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("a", "k", "w1", .fromMilliseconds(30));
    try f.waitPast(r.lease_until orelse return error.TestUnexpectedResult);
    const result = try f.claim("w2", &.{}, &.{"a"}, 1, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 1), result.claimed.len);
    const c = result.claimed[0];
    try testing.expectEqualDeep(@as(?[]const u8, "w2"), c.record.owner);
    try testing.expectEqual(@as(u32, 2), c.record.attempt);
    try testing.expectEqual(@as(u64, 2), c.record.fence);
    const took_over = c.took_over orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("w1", took_over.owner);
    try testing.expectEqual(r.claimed_at, took_over.claimed_at);
    try testing.expectEqual(@as(u32, 1), took_over.attempt);
    try testing.expectEqual(r.scheduled_at, took_over.scheduled_at);

    // Moved by the client during the run of w2: the record shows attempt 0
    // and the new moment; the claim of w2 keeps its own, 2 and the moment
    // of the run, for the claim that takes it over.
    const moved = try f.update("a", "k", c.record.revision, .running, .{ .run_at = .{ .after = .fromSeconds(3600) } });
    if (moved != .updated) return error.TestUnexpectedResult;
    const now = try f.get("a", "k");
    try testing.expectEqual(@as(u32, 0), now.attempt);
    // w2 shortens its lease, and w3 takes it over once it passed.
    const renew: Store.RenewRequest = .{ .ref = .{ .job = "a", .key = "k" }, .life = now.life, .owner = "w2", .fence = 2, .lease = .fromMilliseconds(30) };
    try testing.expectEqual(Store.RenewResult.renewed, try f.store().renew(io, .root, &renew, f.options()));
    try f.waitPast((try f.get("a", "k")).lease_until orelse return error.TestUnexpectedResult);
    const took = try f.claim("w3", &.{}, &.{"a"}, 1, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 1), took.claimed.len);
    try testing.expectEqual(@as(u32, 1), took.claimed[0].record.attempt);
    try testing.expectEqual(now.scheduled_at, took.claimed[0].record.scheduled_at);
    const over = took.claimed[0].took_over orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("w2", over.owner);
    try testing.expectEqual(@as(u32, 2), over.attempt);
    try testing.expectEqual(r.scheduled_at, over.scheduled_at);
    try f.check();
}

test "declared records go only to jobs of any_key" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    _ = try f.create("nightly", "", .{ .after = .fromSeconds(-5) }, 1);
    // A keyed_only job: its declared record stays, and wakes no poll.
    for (0..10) |_| {
        const result = try f.claim("w1", &.{"other"}, &.{"nightly"}, 4, .fromSeconds(60));
        try testing.expectEqual(@as(usize, 0), result.claimed.len);
        try testing.expectEqual(@as(?Io.Duration, null), result.next_in);
    }
    try testing.expectEqual(scheduler.State.pending, (try f.get("nightly", "")).state);
    // Its records with keys go to keyed_only.
    _ = try f.create("nightly", "k", .{ .after = .fromSeconds(-1) }, 1);
    const keyed = try f.claim("w1", &.{}, &.{"nightly"}, 4, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 1), keyed.claimed.len);
    try testing.expectEqualStrings("k", keyed.claimed[0].record.key);
    // An instance that declares the job takes the declaration.
    const declared = try f.claim("w2", &.{"nightly"}, &.{}, 4, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 1), declared.claimed.len);
    try testing.expectEqualStrings("", declared.claimed[0].record.key);
    try f.check();
}

test "renew: renewed, lost, removed, and a lease that expired but was not taken is still renewed" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("a", "k", "w1", .fromMilliseconds(30));
    try f.waitPast(r.lease_until orelse return error.TestUnexpectedResult);
    const ref: scheduler.Ref = .{ .job = "a", .key = "k" };
    const renew: Store.RenewRequest = .{ .ref = ref, .life = r.life, .owner = "w1", .fence = 1, .lease = .fromSeconds(60) };
    const before = f.now();
    try testing.expectEqual(Store.RenewResult.renewed, try f.store().renew(io, .root, &renew, f.options()));
    try expectWithin((try f.get("a", "k")).lease_until orelse return error.TestUnexpectedResult, before.add(.fromSeconds(60)), f.now().add(.fromSeconds(60)));

    var other = renew;
    other.owner = "w2";
    try testing.expectEqual(Store.RenewResult.lost, try f.store().renew(io, .root, &other, f.options()));
    other = renew;
    other.fence = 2;
    try testing.expectEqual(Store.RenewResult.lost, try f.store().renew(io, .root, &other, f.options()));
    other = renew;
    other.life[0] +%= 1;
    try testing.expectEqual(Store.RenewResult.removed, try f.store().renew(io, .root, &other, f.options()));
    _ = try f.store().remove(io, .root, &ref, f.options());
    try testing.expectEqual(Store.RenewResult.removed, try f.store().renew(io, .root, &renew, f.options()));
    try f.check();
}

test "finish: every kind of next, and last = null leaves last alone" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const scheduled: Instant = .fromUnixMs(1_000);

    // Waits again, from .after by the store's clock.
    const r1 = try f.running("a", "after", "w1", .fromSeconds(60));
    const before = f.now();
    try testing.expect(try f.finish(r1, "w1", .{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(5) }, .scheduled_at = null, .attempt = 1 } }, lastOf(r1, .failed, "Declined"), &.{}) == .done);
    const w1 = try f.get("a", "after");
    try testing.expectEqual(scheduler.State.pending, w1.state);
    try expectWithin(w1.run_at orelse return error.TestUnexpectedResult, before.add(.fromSeconds(5)), f.now().add(.fromSeconds(5)));
    try testing.expectEqual(w1.run_at.?, w1.scheduled_at);
    try testing.expectEqual(@as(u32, 1), w1.attempt);
    try testing.expectEqual(@as(?[]const u8, null), w1.owner);
    try testing.expectEqual(@as(?Instant, null), w1.lease_until);
    const last = w1.last orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.failed, last.outcome);
    try testing.expectEqualDeep(@as(?[]const u8, "Declined"), last.error_name);
    try expectWithin(last.finished_at, before, f.now());

    // Waits paused at a moment, with its own scheduled_at and unreadable_since.
    const r2 = try f.running("a", "paused", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r2, "w1", .{ .wait = .{ .state = .paused, .run_at = .{ .at = .fromUnixMs(9_000) }, .scheduled_at = scheduled, .attempt = 0, .unreadable_since = .fromUnixMs(500) } }, null, &.{}) == .done);
    const w2 = try f.get("a", "paused");
    try testing.expectEqual(scheduler.State.paused, w2.state);
    try testing.expectEqual(@as(?Instant, .fromUnixMs(9_000)), w2.run_at);
    try testing.expectEqual(scheduled, w2.scheduled_at);
    try testing.expectEqual(@as(?Instant, .fromUnixMs(500)), w2.unreadable_since);
    try testing.expectEqual(@as(?scheduler.LastRun, null), w2.last);

    // Done for a time, done always, and removed.
    const r3 = try f.running("a", "kept", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r3, "w1", .{ .done = .{ .state = .succeeded, .keep = .{ .keep_for = .fromSeconds(60) } } }, lastOf(r3, .succeeded, null), &.{}) == .done);
    const d3 = try f.get("a", "kept");
    try testing.expectEqual(scheduler.State.succeeded, d3.state);
    const finished_at = d3.finished_at orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?Instant, finished_at.add(.fromSeconds(60))), d3.expires_at);
    try testing.expectEqual(@as(?Instant, null), d3.run_at);
    const r4 = try f.running("a", "always", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r4, "w1", .{ .done = .{ .state = .failed, .keep = .forever } }, null, &.{}) == .done);
    const d4 = try f.get("a", "always");
    try testing.expectEqual(scheduler.State.failed, d4.state);
    try testing.expect(d4.finished_at != null and d4.expires_at == null);
    const r5 = try f.running("a", "gone", "w1", .fromSeconds(60));
    try testing.expect(try f.finish(r5, "w1", .delete, null, &.{}) == .done);
    try testing.expectEqual(@as(?Record, null), try f.store().get(io, .root, &.{ .job = "a", .key = "gone" }, f.options()));

    // last = null leaves the last run of an earlier finish.
    const again = (try f.claim("w1", &.{}, &.{"a"}, 1, .fromSeconds(60))).claimed;
    try testing.expectEqual(@as(usize, 0), again.len);
    _ = try f.update("a", "after", w1.revision, .pending, .{ .run_at = .{ .after = .fromSeconds(-1) } });
    const r6 = try one(try f.claim("w1", &.{}, &.{"a"}, 1, .fromSeconds(60)));
    try testing.expect(try f.finish(r6, "w1", .{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(60) }, .scheduled_at = null, .attempt = 0 } }, null, &.{}) == .done);
    const kept_last = (try f.get("a", "after")).last orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(@as(?[]const u8, "Declined"), kept_last.error_name);

    var d: scheduler.Diagnostics = .{};
    const bad = f.store().finish(io, .root, &.{ .ref = .{ .job = "a", .key = "after" }, .life = r6.life, .owner = "w1", .fence = r6.fence, .revision = r6.revision, .tag = @splat(0), .next = .{ .done = .{ .state = .succeeded, .keep = .none } }, .last = null }, .{ .allocator = f.arena.allocator(), .diagnostics = &d });
    try testing.expectError(error.InvalidArgument, bad);
    try f.check();
}

test "finish of another fence is lost, of another revision changed with the record" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("a", "k", "w1", .fromSeconds(60));
    const wait: Store.Next = .{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(60) }, .scheduled_at = null, .attempt = 0 } };
    var stale = r;
    stale.fence += 1;
    try testing.expect(try f.finish(stale, "w1", wait, null, &.{}) == .lost);
    try testing.expect(try f.finish(r, "w2", wait, null, &.{}) == .lost);
    // A change of the client during the run: another revision.
    try testing.expect(try f.update("a", "k", 0, .running, .{ .run_at = .{ .after = .fromSeconds(30) } }) == .updated);
    const changed = try f.finish(r, "w1", wait, null, &.{});
    try testing.expect(changed == .changed);
    try testing.expectEqual(@as(u64, 1), changed.changed.revision);
    try testing.expectEqual(scheduler.State.running, changed.changed.state);
    try testing.expectEqual(@as(u32, 0), changed.changed.attempt);
    try testing.expectEqual(@as(?Instant, null), changed.changed.run_at);
    var current = r;
    current.revision = 1;
    try testing.expect(try f.finish(current, "w1", wait, null, &.{}) == .done);
    try f.check();
}

test "finish after remove is lost and still writes its history row" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("a", "k", "w1", .fromSeconds(60));
    try testing.expect(try f.store().remove(io, .root, &.{ .job = "a", .key = "k" }, f.options()));
    const row = rowOf(r, .interrupted, "Cancelled", "w1");
    try testing.expect(try f.finish(r, "w1", .delete, null, &.{row}) == .lost);
    const runs = try f.history(.{ .job = "a", .key = "k" });
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqual(scheduler.RunOutcome.interrupted, runs[0].outcome);
    try testing.expectEqualDeep(@as(?[]const u8, "Cancelled"), runs[0].error_name);
    try testing.expectEqualSlices(u8, &r.life, &runs[0].life);
    try f.check();
}

test "finish clears pause_requested" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const r = try f.running("a", "k", "w1", .fromSeconds(60));
    try testing.expect(try f.update("a", "k", 0, .running, .{ .pause_requested = true }) == .updated);
    var current = r;
    current.revision = 1;
    try testing.expect(try f.finish(current, "w1", .{ .wait = .{ .state = .paused, .run_at = .{ .after = .fromSeconds(60) }, .scheduled_at = null, .attempt = 0 } }, null, &.{}) == .done);
    const paused = try f.get("a", "k");
    try testing.expectEqual(scheduler.State.paused, paused.state);
    try testing.expect(!paused.pause_requested);
    try f.check();
}

test "a removed and re-created key is a new life for the same owner and fence" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const old = try f.running("a", "k", "w1", .fromSeconds(60));
    _ = try f.store().remove(io, .root, &.{ .job = "a", .key = "k" }, f.options());
    _ = try f.create("a", "k", .{ .after = .fromSeconds(-1) }, 2);
    const fresh = try one(try f.claim("w1", &.{}, &.{"a"}, 1, .fromSeconds(60)));
    try testing.expectEqual(old.fence, fresh.fence);
    try testing.expectEqualDeep(old.owner, fresh.owner);

    const renew: Store.RenewRequest = .{ .ref = .{ .job = "a", .key = "k" }, .life = old.life, .owner = "w1", .fence = old.fence, .lease = .fromSeconds(1) };
    try testing.expectEqual(Store.RenewResult.removed, try f.store().renew(io, .root, &renew, f.options()));
    const row = rowOf(old, .interrupted, "Cancelled", "w1");
    try testing.expect(try f.finish(old, "w1", .delete, null, &.{row}) == .lost);
    // The new life is untouched: still running, with its lease.
    const now = try f.get("a", "k");
    try testing.expectEqual(scheduler.State.running, now.state);
    try testing.expectEqual(@as(u8, 2), now.life[0]);
    try testing.expectEqual(fresh.lease_until, now.lease_until);
    const runs = try f.history(.{});
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualSlices(u8, &old.life, &runs[0].life);
    try f.check();
}

test "history rows are unique by (life, fence) and the owner's row replaces abandoned" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    const first = try f.running("a", "k", "w1", .fromMilliseconds(30));
    try f.waitPast(first.lease_until orelse return error.TestUnexpectedResult);
    const second = try one(try f.claim("w2", &.{}, &.{"a"}, 1, .fromSeconds(60)));
    // The new owner reports the abandoned attempt and its own run.
    const abandoned = rowOf(first, .abandoned, null, "w1");
    const own = rowOf(second, .succeeded, null, "w2");
    try testing.expect(try f.finish(second, "w2", .{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(60) }, .scheduled_at = null, .attempt = 0 } }, null, &.{ abandoned, own }) == .done);
    var runs = try f.history(.{ .job = "a", .key = "k" });
    try testing.expectEqual(@as(usize, 2), runs.len);
    // The newest first: both written at once, the later one first.
    try testing.expectEqual(@as(u64, 2), runs[0].fence);
    try testing.expectEqual(scheduler.RunOutcome.abandoned, runs[1].outcome);
    try testing.expectEqual(@as(usize, 1), (try f.history(.{ .outcome = .abandoned })).len);

    // The late owner's own row replaces abandoned; its transition is lost.
    try testing.expect(try f.finish(first, "w1", .delete, null, &.{rowOf(first, .interrupted, "LeaseLost", "w1")}) == .lost);
    // Another row of a (life, fence) that has one changes nothing.
    try testing.expect(try f.finish(first, "w1", .delete, null, &.{ rowOf(first, .abandoned, null, "w3"), rowOf(second, .failed, "Again", "w2") }) == .lost);
    runs = try f.history(.{ .job = "a" });
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqual(@as(usize, 0), (try f.history(.{ .outcome = .abandoned })).len);
    const lost = try f.history(.{ .outcome = .interrupted });
    try testing.expectEqual(@as(usize, 1), lost.len);
    try testing.expectEqualDeep(@as(?[]const u8, "LeaseLost"), lost[0].error_name);
    try testing.expectEqual(@as(usize, 1), (try f.history(.{ .outcome = .succeeded })).len);

    // Pages of one, the newest first, each row once.
    var after: ?[]const u8 = null;
    var fences: [2]u64 = undefined;
    var n: usize = 0;
    while (true) {
        const page = try f.store().history(io, .root, &.{ .filter = .{ .key = "k" }, .page = .{ .after = after, .limit = 1 } }, f.options());
        for (page.runs) |run| {
            fences[n] = run.fence;
            n += 1;
        }
        after = page.next orelse break;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual([2]u64{ 1, 2 }, fences);
    try f.check();
}

/// The finish of the claim of `r` by "w1", succeeded: the record and the
/// row of its run are kept for `keep`.
fn finishKept(f: *Fixture, r: Record, keep: Io.Duration) !Store.FinishResult {
    return f.store().finish(io, .root, &.{
        .ref = .{ .job = r.job, .key = r.key },
        .life = r.life,
        .owner = "w1",
        .fence = r.fence,
        .revision = r.revision,
        .tag = @splat(4),
        .next = .{ .done = .{ .state = .succeeded, .keep = .{ .keep_for = keep } } },
        .last = null,
        .history = .{ .runs = &.{rowOf(r, .succeeded, null, "w1")}, .keep = .{ .keep_for = keep } },
    }, f.options());
}

test "keep_for sets expires_at; expired records and rows are gone and never claimed" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    // Kept for an hour: expires_at is finished_at and the hour, on the
    // record and on the row.
    const hour = try f.running("a", "hour", "w1", .fromSeconds(60));
    try testing.expect(try finishKept(&f, hour, .fromSeconds(3600)) == .done);
    const kept = try f.get("a", "hour");
    const finished_at = kept.finished_at orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?Instant, finished_at.add(.fromSeconds(3600))), kept.expires_at);
    const rows = try f.history(.{ .key = "hour" });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(?Instant, rows[0].finished_at.add(.fromSeconds(3600))), rows[0].expires_at);

    // Kept for 40 ms: once the store's clock is past the end of the finish
    // and 40 ms, the record and its row are gone, and no claim takes the
    // record. Nothing is read before they expire.
    const brief = try f.running("a", "brief", "w1", .fromSeconds(60));
    try testing.expect(try finishKept(&f, brief, .fromMilliseconds(40)) == .done);
    try f.waitPast(f.now().add(.fromMilliseconds(40)));
    try testing.expectEqual(@as(?Record, null), try f.store().get(io, .root, &.{ .job = "a", .key = "brief" }, f.options()));
    try testing.expectEqual(@as(usize, 0), (try f.history(.{ .key = "brief" })).len);
    try testing.expectEqual(@as(usize, 0), (try f.claim("w1", &.{"a"}, &.{}, 5, .fromSeconds(60))).claimed.len);
    const left = (try f.store().list(io, .root, &.{ .filter = .{}, .page = .{} }, f.options())).records;
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("hour", left[0].key);
    try f.check();
}

test "max_finished and max_history evict the oldest, with one warning" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var f: Fixture = .init(.{ .max_finished = 2, .max_history = 3 });
    defer f.deinit();
    for ([_][]const u8{ "k0", "k1", "k2", "k3" }) |key| {
        const r = try f.running("a", key, "w1", .fromSeconds(60));
        try testing.expect(try f.finish(r, "w1", .{ .done = .{ .state = .succeeded, .keep = .forever } }, null, &.{rowOf(r, .succeeded, null, "w1")}) == .done);
        try f.check();
    }
    const page = try f.store().list(io, .root, &.{ .filter = .{}, .page = .{} }, f.options());
    try testing.expectEqual(@as(usize, 2), page.records.len);
    try testing.expectEqualStrings("k2", page.records[0].key);
    try testing.expectEqualStrings("k3", page.records[1].key);
    const runs = try f.history(.{});
    try testing.expectEqual(@as(usize, 3), runs.len);
    for (runs, [_][]const u8{ "k3", "k2", "k1" }) |run, key| try testing.expectEqualStrings(key, run.key);
    // One warning of each kind, and no more.
    try testing.expect(f.memory.table.warned.records and f.memory.table.warned.rows);
    try testing.expectEqual(Table.Evictions{}, f.memory.table.takeEvictions());
}

test "next_in is the time to the nearest record the claim would take" {
    var f: Fixture = .init(.{});
    defer f.deinit();
    try testing.expectEqual(@as(?Io.Duration, null), (try f.claim("w1", &.{}, &.{"a"}, 4, .fromSeconds(60))).next_in);
    _ = try f.create("a", "later", .{ .after = .fromSeconds(5) }, 1);
    _ = try f.create("b", "sooner", .{ .after = .fromSeconds(2) }, 1);
    const empty = try f.claim("w1", &.{}, &.{"a"}, 4, .fromSeconds(60));
    try testing.expectEqual(@as(usize, 0), empty.claimed.len);
    const next_in = empty.next_in orelse return error.TestUnexpectedResult;
    try testing.expect(next_in.nanoseconds > 4 * std.time.ns_per_s and next_in.nanoseconds <= 5 * std.time.ns_per_s);
    // A claim of fewer than max counts its own leases too: the nearer wins.
    _ = try f.create("a", "due", .{ .after = .fromSeconds(-1) }, 1);
    const fewer = try f.claim("w1", &.{}, &.{ "a", "b" }, 4, .fromSeconds(1));
    try testing.expectEqual(@as(usize, 1), fewer.claimed.len);
    const lease = fewer.next_in orelse return error.TestUnexpectedResult;
    try testing.expect(lease.nanoseconds > 0 and lease.nanoseconds <= std.time.ns_per_s);
    // A full claim does not look further.
    _ = try f.create("a", "due-2", .{ .after = .fromSeconds(-1) }, 1);
    try testing.expectEqual(@as(?Io.Duration, null), (try f.claim("w1", &.{}, &.{"a"}, 1, .fromSeconds(60))).next_in);
    try f.check();
}
