//! Tests of the records of declared jobs: which names of `Jobs` a claim
//! takes with any key, the record a declaration wants, and what the start
//! of a worker does with the record of a declaration that it finds. `now`
//! is 2026-10-24T10:00:00Z, a Saturday.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const declared = @import("../worker/declared.zig");
const Store = scheduler.Store;
const Instant = scheduler.Instant;
const Record = scheduler.Record;
const State = scheduler.State;

const io = testing.io;
const now: Instant = .fromUtc(2026, 10, 24, 10, 0, 0, .h24);
const life: scheduler.Life = @splat(9);

/// A one-shot job with a payload: its records have keys.
const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };
    pub const Payload = struct { order_id: u64 };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

/// A job without `.repeat` and without a payload.
const Reminder = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "reminder" };

    pub fn run(self: *Reminder, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

/// A declared job without a payload.
const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(3, 30, 0, .am) };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

/// The same declaration in a newer version of the code, at another time.
const NightlyCleanupV2 = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(4, 0, 0, .am) };

    pub fn run(self: *NightlyCleanupV2, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

/// A declared job whose payload has a default for every field.
const Digest = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "digest", .repeat = .weeklyOn(.monday, 9, 0, 0, .am) };
    pub const Payload = struct {
        limit: u32 = 10,
        note: ?[]const u8 = null,
        tags: []const []const u8 = &.{ "orders", "refunds" },
    };

    pub fn run(self: *Digest, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

/// A declared job that waits a fixed delay after each run.
const Heartbeat = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "heartbeat", .repeat = .fixedDelay(.fromSeconds(30)) };

    pub fn run(self: *Heartbeat, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "split puts the jobs with repeat in any_key" {
    const Jobs = struct { invoices: *SendInvoiceJob, cleanup: *NightlyCleanup, digest: *Digest, reminders: *Reminder };
    const names = declared.split(Jobs);
    try expectNames(&.{ "nightly-cleanup", "digest" }, names.any_key);
    try expectNames(&.{ "send-invoice", "reminder" }, names.keyed_only);
    // The names are known at compile time: a worker claims without memory
    // for them.
    comptime std.debug.assert(declared.split(Jobs).any_key.len == 2);

    const keyed = declared.split(struct { invoices: *SendInvoiceJob });
    try expectNames(&.{}, keyed.any_key);
    try expectNames(&.{"send-invoice"}, keyed.keyed_only);
    const repeating = declared.split(struct { cleanup: *NightlyCleanup });
    try expectNames(&.{"nightly-cleanup"}, repeating.any_key);
    try expectNames(&.{}, repeating.keyed_only);
}

test "a declared job wants key \"\", its plan and Payload{}" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Without Payload: "{}", and the first run of its plan after now.
    var request = try declared.wanted(NightlyCleanup, a, now, life);
    try testing.expectEqualStrings("nightly-cleanup", request.job);
    try testing.expectEqualStrings("", request.key);
    try testing.expect(request.tenant == null);
    try testing.expect(request.trace == null);
    try testing.expectEqualSlices(u8, &life, &request.life);
    try testing.expectEqualStrings("daily 03:30:00", request.plan);
    try testing.expectEqualStrings("{}", request.payload);
    try testing.expectEqual(Store.Moment{ .at = .fromUtc(2026, 10, 25, 3, 30, 0, .h24) }, request.run_at);

    // fixedDelay: its delay after the store takes the record.
    request = try declared.wanted(Heartbeat, a, now, life);
    try testing.expectEqualStrings("delay 30s", request.plan);
    try testing.expectEqual(Store.Moment{ .after = .fromSeconds(30) }, request.run_at);

    // With Payload: the JSON of Payload{}, on Monday at 9.
    request = try declared.wanted(Digest, a, now, life);
    try testing.expectEqualStrings("weekly mon 09:00:00", request.plan);
    try testing.expectEqualStrings("{\"limit\":10,\"note\":null,\"tags\":[\"orders\",\"refunds\"]}", request.payload);
    try testing.expectEqual(Store.Moment{ .at = .fromUtc(2026, 10, 26, 9, 0, 0, .h24) }, request.run_at);
    // A store creates it as it is, and its payload reads back as the
    // defaults.
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    const store = memory.store();
    try testing.expectEqual(Store.CreateResult.created, try store.create(io, .root, &request, .{ .allocator = a }));
    const r = (try store.get(io, .root, &.declared(Digest), .{ .allocator = a })) orelse return error.TestUnexpectedResult;
    const payload = try r.payloadAs(Digest, a);
    try testing.expectEqual(@as(u32, 10), payload.limit);
    try testing.expectEqual(@as(usize, 2), payload.tags.len);
}

/// A record of a declaration as a store keeps it, in `state`.
fn found(state: State, plan: []const u8) Record {
    const at: Instant = .fromUtc(2026, 10, 25, 3, 30, 0, .h24);
    return .{
        .job = "nightly-cleanup",
        .key = "",
        .tenant = null,
        .state = state,
        .plan = plan,
        .payload = "{}",
        .scheduled_at = at,
        .run_at = if (state == .running) null else at,
        .attempt = if (state == .running) 1 else 0,
        .fence = 4,
        .revision = 2,
        .pause_requested = false,
        .owner = if (state == .running) "shop/00112233445566778899aabbccddeeff" else null,
        .claimed_at = if (state == .running) at else null,
        .lease_until = if (state == .running) at.add(.fromSeconds(60)) else null,
        .last = null,
        .created_at = now,
        .updated_at = now,
        .finished_at = null,
        .expires_at = null,
        .trace = null,
        .life = life,
        .unreadable_since = null,
    };
}

test "reconcile leaves a record of the same plan alone" {
    const first: Store.Moment = .{ .at = .fromUtc(2026, 10, 25, 3, 30, 0, .h24) };
    for ([_]State{ .pending, .running, .paused }) |state| {
        const r = found(state, "daily 03:30:00");
        try testing.expect(declared.reconcile(&r, "daily 03:30:00", first) == null);
    }
}

test "another plan: the plan and the next run" {
    const first: Store.Moment = .{ .at = .fromUtc(2026, 10, 25, 4, 0, 0, .h24) };
    for ([_]State{ .pending, .paused }) |state| {
        const r = found(state, "daily 03:30:00");
        const patch = declared.reconcile(&r, "daily 04:00:00", first) orelse return error.TestUnexpectedResult;
        try testing.expectEqualDeep(@as(?[]const u8, "daily 04:00:00"), patch.plan);
        try testing.expectEqual(@as(?Store.Moment, first), patch.run_at);
        try testing.expect(patch.state == null and patch.pause_requested == null and !patch.reset);
    }

    // The start of a newer version: its record is there with the old plan,
    // and the patch, on condition of the record's revision, moves it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    const store = memory.store();
    const old = try declared.wanted(NightlyCleanup, a, now, life);
    try testing.expectEqual(Store.CreateResult.created, try store.create(io, .root, &old, .{ .allocator = a }));
    const new = try declared.wanted(NightlyCleanupV2, a, now, @splat(10));
    try testing.expectEqual(Store.CreateResult.existing, try store.create(io, .root, &new, .{ .allocator = a }));
    const r = (try store.get(io, .root, &.declared(NightlyCleanupV2), .{ .allocator = a })) orelse return error.TestUnexpectedResult;
    const patch = declared.reconcile(&r, new.plan, new.run_at) orelse return error.TestUnexpectedResult;
    const updated = try store.update(io, .root, &.{ .ref = .declared(NightlyCleanupV2), .expect = .{ .life = r.life, .revision = r.revision, .state = r.state }, .set = patch, .tag = @splat(1) }, .{ .allocator = a });
    try testing.expect(updated == .updated);
    const moved = (try store.get(io, .root, &.declared(NightlyCleanupV2), .{ .allocator = a })) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("daily 04:00:00", moved.plan);
    try testing.expectEqual(@as(?Instant, .fromUtc(2026, 10, 25, 4, 0, 0, .h24)), moved.run_at);
    try testing.expectEqualSlices(u8, &life, &moved.life);
}

test "a running record gets only the plan" {
    const r = found(.running, "daily 03:30:00");
    const patch = declared.reconcile(&r, "daily 04:00:00", .{ .at = .fromUtc(2026, 10, 25, 4, 0, 0, .h24) }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(@as(?[]const u8, "daily 04:00:00"), patch.plan);
    try testing.expect(patch.run_at == null);
    try testing.expect(patch.state == null and patch.pause_requested == null and !patch.reset);

    // A store takes it while the run goes on: the run keeps its moment, and
    // the next one comes from the new plan.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    const store = memory.store();
    var due = try declared.wanted(NightlyCleanup, a, now, life);
    due.run_at = .{ .at = .fromUnixMs(0) };
    _ = try store.create(io, .root, &due, .{ .allocator = a });
    const claim: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{"nightly-cleanup"}, .keyed_only = &.{}, .max = 1, .lease = .fromSeconds(60), .tag = @splat(2) };
    const claimed = (try store.claim(io, .root, &claim, .{ .allocator = a })).claimed;
    if (claimed.len != 1) return error.TestUnexpectedResult;
    const running = claimed[0].record;
    const replan = declared.reconcile(&running, "daily 04:00:00", .{ .at = .fromUtc(2026, 10, 25, 4, 0, 0, .h24) }) orelse return error.TestUnexpectedResult;
    const updated = try store.update(io, .root, &.{ .ref = .declared(NightlyCleanup), .expect = .{ .life = running.life, .revision = running.revision, .state = .running }, .set = replan, .tag = @splat(3) }, .{ .allocator = a });
    try testing.expect(updated == .updated);
    const now_r = (try store.get(io, .root, &.declared(NightlyCleanup), .{ .allocator = a })) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(State.running, now_r.state);
    try testing.expectEqualStrings("daily 04:00:00", now_r.plan);
    try testing.expectEqual(running.scheduled_at, now_r.scheduled_at);
    try testing.expectEqual(running.attempt, now_r.attempt);
}
