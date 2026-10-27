//! Tests of the changes of scheduler.Client on a MemoryStore: pause,
//! unpause, reschedule, retry and cancel in every state, what a claim takes
//! after them, and changes that race.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const scheduler = @import("../root.zig");
const client_fixture = @import("client_fixture.zig");
const SendInvoice = client_fixture.SendInvoice;
const WeeklyReport = client_fixture.WeeklyReport;
const Fixture = client_fixture.Fixture;
const Store = scheduler.Store;
const StoreError = scheduler.StoreError;
const Instant = scheduler.Instant;
const Changed = scheduler.Client.Changed;

const io = testing.io;

const order: scheduler.Ref = .of(SendInvoice, "order-42");
const small: SendInvoice.Payload = .{ .order_id = 42, .amount_cents = 1999 };
/// A moment long past: due at once.
const past: Instant = .fromUnixMs(0);
const at: Instant = .fromUtc(2030, 1, 2, 3, 4, 5, .h24);

/// Schedules SendInvoice with `key` for `when`.
fn invoice(f: *Fixture, key: []const u8, when: scheduler.When) !void {
    if (try f.client.schedule(io, .root, SendInvoice, .{ .key = key, .when = when, .payload = small }, .{}) != .created) return error.TestUnexpectedResult;
}

test "pause and unpause in every state" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const c = &f.client;
    try testing.expectEqual(Changed.not_found, try c.pause(io, .root, order, .{}));
    try testing.expectEqual(Changed.not_found, try c.unpause(io, .root, order, .{}));

    // Pending and due: paused, no claim takes it; unpaused, its past run_at
    // runs at once.
    try invoice(&f, "order-42", .{ .at = past });
    try testing.expectEqual(Changed.unchanged, try c.unpause(io, .root, order, .{}));
    try testing.expectEqual(Changed.changed, try c.pause(io, .root, order, .{}));
    var r = try f.record(order);
    try testing.expectEqual(scheduler.State.paused, r.state);
    try testing.expectEqual(@as(?Instant, past), r.run_at);
    try testing.expectEqual(@as(u64, 1), r.revision);
    try testing.expectEqual(Changed.unchanged, try c.pause(io, .root, order, .{}));
    try testing.expectEqual(@as(usize, 0), (try f.claim("send-invoice")).len);
    try testing.expectEqual(Changed.changed, try c.unpause(io, .root, order, .{}));
    r = try f.record(order);
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(u64, 2), r.revision);
    try testing.expectEqual(@as(usize, 1), (try f.claim("send-invoice")).len);

    // Running: the pause is asked for and taken back; the run goes on.
    try testing.expectEqual(Changed.unchanged, try c.unpause(io, .root, order, .{}));
    try testing.expectEqual(Changed.changed, try c.pause(io, .root, order, .{}));
    r = try f.record(order);
    try testing.expectEqual(scheduler.State.running, r.state);
    try testing.expect(r.pause_requested);
    try testing.expectEqual(Changed.unchanged, try c.pause(io, .root, order, .{}));
    try testing.expectEqual(Changed.changed, try c.unpause(io, .root, order, .{}));
    r = try f.record(order);
    try testing.expect(!r.pause_requested);
    try testing.expectEqual(@as(u64, 4), r.revision);

    // Finished.
    try testing.expect(try f.finish(r, .{ .done = .{ .state = .failed, .keep = .forever } }) == .done);
    try testing.expectEqual(Changed.finished, try c.pause(io, .root, order, .{}));
    try testing.expectEqual(Changed.finished, try c.unpause(io, .root, order, .{}));
}

test "cancel removes a record in any state" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const c = &f.client;
    _ = try f.failed("failed");
    try invoice(&f, "running", .{ .at = past });
    try testing.expectEqual(@as(usize, 1), (try f.claim("send-invoice")).len);
    try invoice(&f, "paused", .{ .after = .fromSeconds(3600) });
    try testing.expectEqual(Changed.changed, try c.pause(io, .root, .of(SendInvoice, "paused"), .{}));
    try invoice(&f, "pending", .{ .after = .fromSeconds(3600) });
    // The parked record of a declaration, which only a worker makes.
    const declared: Store.CreateRequest = .{ .job = "send-invoice", .key = "", .life = @splat(9), .plan = "every 60s", .payload = "{}", .run_at = .{ .after = .zero } };
    _ = try f.store().create(io, .root, &declared, f.options());

    for ([_]scheduler.Ref{ .of(SendInvoice, "failed"), .of(SendInvoice, "running"), .of(SendInvoice, "paused"), .of(SendInvoice, "pending"), .declared(SendInvoice) }) |ref| {
        try testing.expect(try c.cancel(io, .root, ref, .{}));
        try testing.expectEqual(@as(?scheduler.Record, null), try f.store().get(io, .root, &ref, f.options()));
        try testing.expect(!try c.cancel(io, .root, ref, .{}));
    }
}

test "reschedule moves a one-shot job and changes the schedule of a recurring one" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const c = &f.client;

    // Pending: .at.
    try invoice(&f, "pending", .{ .after = .fromSeconds(3600) });
    try testing.expectEqual(Changed.changed, try c.reschedule(io, .root, .of(SendInvoice, "pending"), .{ .at = at }, .{}));
    var r = try f.record(.of(SendInvoice, "pending"));
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(?Instant, at), r.run_at);
    try testing.expectEqual(at, r.scheduled_at);
    try testing.expectEqualStrings("", r.plan);
    try testing.expectEqual(@as(u64, 1), r.revision);

    // Paused: .after, by the store's clock, and it stays paused.
    try invoice(&f, "paused", .{ .after = .fromSeconds(3600) });
    _ = try c.pause(io, .root, .of(SendInvoice, "paused"), .{});
    var from = f.store().now(io);
    try testing.expectEqual(Changed.changed, try c.reschedule(io, .root, .of(SendInvoice, "paused"), .{ .after = .fromSeconds(7200) }, .{}));
    var to = f.store().now(io);
    r = try f.record(.of(SendInvoice, "paused"));
    try testing.expectEqual(scheduler.State.paused, r.state);
    try expectWithin(r.run_at, from.unix_ms + 7_200_000, to.unix_ms + 7_200_000);

    // Running: it keeps running; the run it waits for is new, from attempt 0.
    try invoice(&f, "running", .{ .at = past });
    const claimed = try f.claim("send-invoice");
    try testing.expectEqual(@as(usize, 1), claimed.len);
    try testing.expectEqual(Changed.changed, try c.reschedule(io, .root, .of(SendInvoice, "running"), .{ .at = at }, .{}));
    r = try f.record(.of(SendInvoice, "running"));
    try testing.expectEqual(scheduler.State.running, r.state);
    try testing.expectEqual(claimed[0].record.revision + 1, r.revision);
    try testing.expectEqual(@as(?Instant, null), r.run_at);
    try testing.expectEqual(at, r.scheduled_at);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(claimed[0].record.fence, r.fence);

    // Recurring: .at moves the next run and keeps the plan; .repeat
    // changes the plan and starts at its first moment.
    _ = try c.schedule(io, .root, WeeklyReport, .{ .key = "acme", .when = .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) } }, .{});
    const acme: scheduler.Ref = .of(WeeklyReport, "acme");
    try testing.expectEqual(Changed.changed, try c.reschedule(io, .root, acme, .{ .at = at }, .{}));
    r = try f.record(acme);
    try testing.expectEqualStrings("weekly mon 09:00:00", r.plan);
    try testing.expectEqual(@as(?Instant, at), r.run_at);
    const nightly: scheduler.Schedule = .dailyAt(3, 30, 0, .am);
    from = f.store().now(io);
    try testing.expectEqual(Changed.changed, try c.reschedule(io, .root, acme, .{ .repeat = nightly }, .{}));
    to = f.store().now(io);
    r = try f.record(acme);
    try testing.expectEqualStrings("daily 03:30:00", r.plan);
    try expectFirst(nightly, r.run_at, from, to);

    // Finished, missing, and a when that is none, refused before any I/O.
    _ = try f.failed("failed");
    try testing.expectEqual(Changed.finished, try c.reschedule(io, .root, .of(SendInvoice, "failed"), .{ .at = at }, .{}));
    try testing.expectEqual(Changed.not_found, try c.reschedule(io, .root, .of(SendInvoice, "missing"), .{ .at = at }, .{}));
    const gets = f.faulty.calls(io, .get);
    var d: scheduler.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, c.reschedule(io, .root, order, .{ .after = .fromSeconds(-1) }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("when: .after is -1s; a delay is 0 to 100 years", d.message());
    try testing.expectError(error.InvalidArgument, c.reschedule(io, .root, order, .{ .at = .invalid }, .{}));
    try testing.expectEqual(gets, f.faulty.calls(io, .get));
}

test "a one-shot job rescheduled with repeat becomes recurring" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    try invoice(&f, "order-42", .{ .after = .fromSeconds(3600) });
    const every: scheduler.Schedule = .everyMinutes(5);
    var from = f.store().now(io);
    try testing.expectEqual(Changed.changed, try f.client.reschedule(io, .root, order, .{ .repeat = every }, .{}));
    var to = f.store().now(io);
    var r = try f.record(order);
    try testing.expectEqualStrings("every 300s", r.plan);
    try testing.expectEqual(scheduler.State.pending, r.state);
    try expectFirst(every, r.run_at, from, to);
    try testing.expectEqualStrings("{\"order_id\":42,\"amount_cents\":1999,\"note\":null}", r.payload);

    // fixedDelay starts its delay after the change.
    from = f.store().now(io);
    try testing.expectEqual(Changed.changed, try f.client.reschedule(io, .root, order, .{ .repeat = .fixedDelay(.fromSeconds(30)) }, .{}));
    to = f.store().now(io);
    r = try f.record(order);
    try testing.expectEqualStrings("delay 30s", r.plan);
    try expectWithin(r.run_at, from.unix_ms + 30_000, to.unix_ms + 30_000);
}

test "retry gives a failed job its attempts back at once, with the same scheduled_at" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const c = &f.client;
    const old = try f.failed("order-42");
    try testing.expectEqual(@as(u32, 1), old.attempt);
    const from = f.store().now(io);
    try testing.expectEqual(Changed.changed, try c.retry(io, .root, order, .{}));
    const to = f.store().now(io);
    const r = try f.record(order);
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(old.scheduled_at, r.scheduled_at);
    try expectWithin(r.run_at, from.unix_ms, to.unix_ms);
    try testing.expectEqual(@as(?Instant, null), r.finished_at);
    try testing.expectEqual(@as(?Instant, null), r.expires_at);
    try testing.expectEqual(old.revision + 1, r.revision);
    try testing.expectEqualDeep(old.last, r.last);
    const claimed = try f.claim("send-invoice");
    try testing.expectEqual(@as(usize, 1), claimed.len);
    try testing.expectEqual(@as(u32, 1), claimed[0].record.attempt);
    try testing.expectEqual(old.scheduled_at, claimed[0].record.scheduled_at);

    // A live job is unchanged: running, pending, paused.
    try testing.expectEqual(Changed.unchanged, try c.retry(io, .root, order, .{}));
    try invoice(&f, "pending", .{ .after = .fromSeconds(3600) });
    try testing.expectEqual(Changed.unchanged, try c.retry(io, .root, .of(SendInvoice, "pending"), .{}));
    _ = try c.pause(io, .root, .of(SendInvoice, "pending"), .{});
    try testing.expectEqual(Changed.unchanged, try c.retry(io, .root, .of(SendInvoice, "pending"), .{}));
    // A succeeded one is finished, a missing one not found.
    try invoice(&f, "done", .{ .at = past });
    const done = try f.claim("send-invoice");
    try testing.expectEqual(@as(usize, 1), done.len);
    try testing.expect(try f.finish(done[0].record, .{ .done = .{ .state = .succeeded, .keep = .forever } }) == .done);
    try testing.expectEqual(Changed.finished, try c.retry(io, .root, .of(SendInvoice, "done"), .{}));
    try testing.expectEqual(Changed.not_found, try c.retry(io, .root, .of(SendInvoice, "missing"), .{}));
}

/// Tasks that each make one change of the same record.
const Racer = struct {
    client: *const scheduler.Client,
    changed: std.atomic.Value(u32) = .init(0),
    unchanged: std.atomic.Value(u32) = .init(0),
    other: std.atomic.Value(u32) = .init(0),

    fn run(racer: *Racer, i: usize) void {
        const result = switch (i % 3) {
            0 => racer.client.pause(io, .root, order, .{}),
            1 => racer.client.unpause(io, .root, order, .{}),
            else => racer.client.reschedule(io, .root, order, .{ .after = .fromSeconds(3600) }, .{}),
        };
        const counter = if (result) |changed| switch (changed) {
            .changed => &racer.changed,
            .unchanged => &racer.unchanged,
            .finished, .not_found => &racer.other,
        } else |_| &racer.other;
        _ = counter.fetchAdd(1, .monotonic);
    }
};

test "8 tasks changing one record race and every call ends in changed or unchanged" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    try invoice(&f, "order-42", .{ .after = .fromSeconds(3600) });
    var racer: Racer = .{ .client = &f.client };
    // In each round a call loses at most to the 7 others, each of which
    // changes the record once at most: below the 8 a call may lose.
    for (0..25) |_| {
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (0..8) |i| try group.concurrent(io, Racer.run, .{ &racer, i });
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), racer.other.load(.monotonic));
    const changed = racer.changed.load(.monotonic);
    try testing.expectEqual(@as(u32, 200), changed + racer.unchanged.load(.monotonic));
    // Each change that answered changed is one revision, and no other.
    try testing.expectEqual(@as(u64, changed), (try f.record(order)).revision);
}

/// A store over another whose every update loses its race: a change of
/// another client comes just before it.
const Busy = struct {
    inner: Store,
    updates: u32 = 0,

    pub const name = "busy";

    pub fn now(b: *Busy, _: Io) Instant {
        return b.inner.now(io);
    }
    pub fn create(b: *Busy, _: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) StoreError!Store.CreateResult {
        return b.inner.create(io, ctx, request, options);
    }
    pub fn get(b: *Busy, _: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!?scheduler.Record {
        return b.inner.get(io, ctx, ref, options);
    }
    pub fn update(b: *Busy, _: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) StoreError!Store.UpdateResult {
        b.updates += 1;
        const r = (try b.inner.get(io, ctx, &request.ref, options)) orelse return .not_found;
        const first: Store.UpdateRequest = .{ .ref = request.ref, .expect = .{ .revision = r.revision, .state = r.state }, .set = .{ .pause_requested = r.pause_requested }, .tag = @splat(0) };
        if (try b.inner.update(io, ctx, &first, options) != .updated) return error.Corrupt;
        return b.inner.update(io, ctx, request, options);
    }
    pub fn remove(b: *Busy, _: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!bool {
        return b.inner.remove(io, ctx, ref, options);
    }
    pub fn list(b: *Busy, _: Io, ctx: core.Context, request: *const Store.ListRequest, options: Store.CallOptions) StoreError!scheduler.RecordPage {
        return b.inner.list(io, ctx, request, options);
    }
    pub fn claim(b: *Busy, _: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) StoreError!Store.ClaimResult {
        return b.inner.claim(io, ctx, request, options);
    }
    pub fn renew(b: *Busy, _: Io, ctx: core.Context, request: *const Store.RenewRequest, options: Store.CallOptions) StoreError!Store.RenewResult {
        return b.inner.renew(io, ctx, request, options);
    }
    pub fn finish(b: *Busy, _: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) StoreError!Store.FinishResult {
        return b.inner.finish(io, ctx, request, options);
    }
    pub fn history(b: *Busy, _: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) StoreError!scheduler.RunPage {
        return b.inner.history(io, ctx, request, options);
    }
};

test "Contended after exactly 8 lost updates" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var busy: Busy = .{ .inner = memory.store() };
    const client: scheduler.Client = .init(testing.allocator, io, .init(&busy), .{});
    _ = try client.schedule(io, .root, SendInvoice, .{ .key = "order-42", .when = .{ .after = .fromSeconds(3600) }, .payload = small }, .{});
    var d: scheduler.Diagnostics = .{};
    try testing.expectError(error.Contended, client.pause(io, .root, order, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(u32, 8), busy.updates);
    try testing.expect(d.message().len > 0);
    // Only the other changes were applied.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = (try memory.store().get(io, .root, &order, .{ .allocator = arena.allocator() })) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqual(@as(u64, 8), r.revision);
}

/// `when` is a moment within `[low, high]` in milliseconds.
fn expectWithin(when: ?Instant, low: i64, high: i64) !void {
    const ms = (when orelse return error.TestUnexpectedResult).unix_ms;
    if (ms < low or ms > high) {
        std.debug.print("{d} is not within [{d}, {d}]\n", .{ ms, low, high });
        return error.TestUnexpectedResult;
    }
}

/// `when` is the first moment of `s` after the store's now, read between
/// `from` and `to`.
fn expectFirst(s: scheduler.Schedule, when: ?Instant, from: Instant, to: Instant) !void {
    const first = (when orelse return error.TestUnexpectedResult).unix_ms;
    const earliest = (s.next(from) orelse return error.TestUnexpectedResult).unix_ms;
    const latest = (s.next(to) orelse return error.TestUnexpectedResult).unix_ms;
    try testing.expect(first == earliest or first == latest);
}
