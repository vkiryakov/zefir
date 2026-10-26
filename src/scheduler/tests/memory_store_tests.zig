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

const io = testing.io;

/// A store and an arena for the results of its calls.
const Fixture = struct {
    memory: MemoryStore,
    arena: std.heap.ArenaAllocator,

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

    fn update(f: *Fixture, job: []const u8, key: []const u8, revision: u64, state: scheduler.State, set: Store.Patch) !Store.UpdateResult {
        return f.store().update(io, .root, &.{ .ref = .{ .job = job, .key = key }, .expect = .{ .revision = revision, .state = state }, .set = set, .tag = @splat(9) }, f.options());
    }
};

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

test "update applies on revision and state and raises revision" {
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
        .expect = .{ .revision = 4, .state = .pending },
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
    const update: Store.UpdateRequest = .{ .ref = ref, .expect = .{ .revision = 0, .state = .pending }, .set = .{ .state = .paused }, .tag = @splat(0) };
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
