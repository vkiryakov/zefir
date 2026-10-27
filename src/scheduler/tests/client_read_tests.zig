//! Tests of the reads of scheduler.Client on a MemoryStore: get, list and
//! history, and Record.payloadAs.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const client_fixture = @import("client_fixture.zig");
const SendInvoice = client_fixture.SendInvoice;
const WeeklyReport = client_fixture.WeeklyReport;
const Fixture = client_fixture.Fixture;
const Store = scheduler.Store;
const Record = scheduler.Record;

const io = testing.io;

const order: scheduler.Ref = .of(SendInvoice, "order-42");

test "get returns the record with its strings in the arena" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    _ = try f.client.schedule(io, .root, WeeklyReport, .{ .key = "order-42", .when = .{ .repeat = .everyMinutes(5) }, .tenant = "acme" }, .{});
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const r = (try f.client.get(io, .root, .of(WeeklyReport, "order-42"), fixed.allocator(), .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("weekly-report", r.job);
    try testing.expectEqualStrings("order-42", r.key);
    try testing.expectEqualStrings("every 300s", r.plan);
    try testing.expectEqualStrings("{}", r.payload);
    const tenant = r.tenant orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ r.job, r.key, r.plan, r.payload, tenant }) |text| {
        const at = @intFromPtr(text.ptr);
        try testing.expect(at >= @intFromPtr(&buffer) and at + text.len <= @intFromPtr(&buffer) + buffer.len);
    }
    try testing.expectEqual(@as(?Record, null), try f.client.get(io, .root, order, fixed.allocator(), .{}));
}

/// The keys of the records of `filter`, a page of 7 at a time; each record
/// comes once.
fn listed(f: *Fixture, filter: scheduler.ListFilter) !usize {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const a = f.arena.allocator();
    var after: ?[]const u8 = null;
    while (true) {
        const page = try f.client.list(io, .root, filter, .{ .after = after, .limit = 7 }, a, .{});
        try testing.expect(page.records.len <= 7);
        for (page.records) |r| {
            if (filter.job) |job| try testing.expectEqualStrings(job, r.job);
            if (filter.tenant) |tenant| try testing.expectEqualDeep(@as(?[]const u8, tenant), r.tenant);
            if (filter.state) |state| try testing.expectEqual(state, r.state);
            const id = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.job, r.key });
            if ((try seen.fetchPut(a, id, {})) != null) return error.TestUnexpectedResult;
        }
        after = page.next orelse return seen.count();
    }
}

test "list pages through 50 records filtered by job and by tenant" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    var key: [8]u8 = undefined;
    for (0..30) |i| {
        const tenant: []const u8 = if (i % 2 == 0) "acme" else "globex";
        _ = try f.client.schedule(io, .root, SendInvoice, .{ .key = try std.fmt.bufPrint(&key, "order-{d:0>2}", .{i}), .when = .{ .after = .fromSeconds(3600) }, .payload = .{ .order_id = i, .amount_cents = 1 }, .tenant = tenant }, .{});
    }
    for (0..20) |i| {
        _ = try f.client.schedule(io, .root, WeeklyReport, .{ .key = try std.fmt.bufPrint(&key, "shop-{d:0>2}", .{i}), .when = .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) }, .tenant = "acme" }, .{});
    }
    for (0..3) |i| _ = try f.client.pause(io, .root, .of(SendInvoice, try std.fmt.bufPrint(&key, "order-{d:0>2}", .{i})), .{});

    try testing.expectEqual(@as(usize, 50), try listed(&f, .{}));
    try testing.expectEqual(@as(usize, 30), try listed(&f, .{ .job = "send-invoice" }));
    try testing.expectEqual(@as(usize, 20), try listed(&f, .{ .job = "weekly-report" }));
    try testing.expectEqual(@as(usize, 35), try listed(&f, .{ .tenant = "acme" }));
    try testing.expectEqual(@as(usize, 15), try listed(&f, .{ .job = "send-invoice", .tenant = "globex" }));
    try testing.expectEqual(@as(usize, 3), try listed(&f, .{ .state = .paused }));
    try testing.expectEqual(@as(usize, 0), try listed(&f, .{ .job = "send-invoice", .tenant = "initech" }));
}

/// Claims the record of `ref` for "w1" and finishes it with one row of the
/// history, of `outcome`; `next` says what the record does then. The rows
/// are a millisecond apart at least, so that newest first is one order.
fn finishWith(f: *Fixture, ref: scheduler.Ref, outcome: scheduler.RunOutcome, next: Store.Next) !void {
    const claimed = try f.claim(ref.job);
    if (claimed.len != 1) return error.TestUnexpectedResult;
    const r = claimed[0].record;
    const started = r.claimed_at orelse return error.TestUnexpectedResult;
    const row: scheduler.Run = .{
        .job = r.job,
        .key = r.key,
        .tenant = r.tenant,
        .life = r.life,
        .fence = r.fence,
        .attempt = r.attempt,
        .scheduled_at = r.scheduled_at,
        .started_at = started,
        .finished_at = started,
        .outcome = outcome,
        .error_name = if (outcome == .failed) "PaymentDeclined" else null,
        .instance = "w1",
        .expires_at = null,
    };
    const done = try f.store().finish(io, .root, &.{
        .ref = ref,
        .life = r.life,
        .owner = "w1",
        .fence = r.fence,
        .revision = r.revision,
        .tag = @splat(3),
        .next = next,
        .last = null,
        .history = .{ .runs = &.{row}, .keep = .forever },
    }, f.options());
    if (done != .done) return error.TestUnexpectedResult;
    const now = f.store().now(io);
    while (f.store().now(io).unix_ms <= now.unix_ms) try io.sleep(.fromMilliseconds(1), .awake);
}

/// The outcomes of the rows of `filter`, a page of 2 at a time.
fn outcomes(f: *Fixture, filter: scheduler.HistoryFilter) ![]const scheduler.RunOutcome {
    const a = f.arena.allocator();
    var all: std.ArrayList(scheduler.RunOutcome) = .empty;
    var after: ?[]const u8 = null;
    var last: ?i64 = null;
    while (true) {
        const page = try f.client.history(io, .root, filter, .{ .after = after, .limit = 2 }, a, .{});
        for (page.runs) |run| {
            if (filter.job) |job| try testing.expectEqualStrings(job, run.job);
            if (filter.key) |key| try testing.expectEqualStrings(key, run.key);
            if (last) |ms| try testing.expect(run.finished_at.unix_ms < ms);
            last = run.finished_at.unix_ms;
            try all.append(a, run.outcome);
        }
        after = page.next orelse return all.items;
    }
}

test "history filters by job and key, job, tenant and outcome" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const c = &f.client;
    const due: scheduler.When = .{ .at = .fromUnixMs(0) };
    const weekly: scheduler.Ref = .of(WeeklyReport, "acme");
    _ = try c.schedule(io, .root, SendInvoice, .{ .key = "a", .when = due, .payload = .{ .order_id = 1, .amount_cents = 1 }, .tenant = "acme" }, .{});
    try finishWith(&f, .of(SendInvoice, "a"), .succeeded, .delete);
    _ = try c.schedule(io, .root, SendInvoice, .{ .key = "b", .when = due, .payload = .{ .order_id = 2, .amount_cents = 1 }, .tenant = "globex" }, .{});
    try finishWith(&f, .of(SendInvoice, "b"), .failed, .delete);
    _ = try c.schedule(io, .root, WeeklyReport, .{ .key = "acme", .when = .{ .repeat = .everySeconds(1) }, .tenant = "acme" }, .{});
    _ = try c.reschedule(io, .root, weekly, due, .{});
    try finishWith(&f, weekly, .skipped, .{ .wait = .{ .state = .pending, .run_at = .{ .after = .zero }, .scheduled_at = null, .attempt = 0 } });
    try finishWith(&f, weekly, .abandoned, .{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(60) }, .scheduled_at = null, .attempt = 0 } });
    _ = try c.schedule(io, .root, SendInvoice, .{ .key = "c", .when = due, .payload = .{ .order_id = 3, .amount_cents = 1 }, .tenant = "acme" }, .{});
    try finishWith(&f, .of(SendInvoice, "c"), .abandoned, .delete);

    try testing.expectEqualSlices(scheduler.RunOutcome, &.{ .abandoned, .abandoned, .skipped, .failed, .succeeded }, try outcomes(&f, .{}));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{ .abandoned, .skipped }, try outcomes(&f, .{ .job = "weekly-report", .key = "acme" }));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{ .abandoned, .failed, .succeeded }, try outcomes(&f, .{ .job = "send-invoice" }));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{ .abandoned, .abandoned, .skipped, .succeeded }, try outcomes(&f, .{ .tenant = "acme" }));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{ .abandoned, .abandoned }, try outcomes(&f, .{ .outcome = .abandoned }));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{.skipped}, try outcomes(&f, .{ .outcome = .skipped }));
    try testing.expectEqualSlices(scheduler.RunOutcome, &.{}, try outcomes(&f, .{ .job = "send-invoice", .outcome = .skipped }));
}

test "payloadAs reads the payload of the job" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const a = f.arena.allocator();
    _ = try f.client.schedule(io, .root, SendInvoice, .{ .key = "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 42, .amount_cents = 1999, .note = "gift" } }, .{});
    const r = (try f.client.get(io, .root, order, a, .{})) orelse return error.TestUnexpectedResult;
    const p = try r.payloadAs(SendInvoice, a);
    try testing.expectEqual(@as(u64, 42), p.order_id);
    try testing.expectEqual(@as(u64, 1999), p.amount_cents);
    try testing.expectEqualDeep(@as(?[]const u8, "gift"), p.note);
    // A job without Payload reads its object as void.
    _ = try f.client.schedule(io, .root, WeeklyReport, .{ .key = "acme", .when = .{ .repeat = .everyMinutes(5) } }, .{});
    const weekly = (try f.client.get(io, .root, .of(WeeklyReport, "acme"), a, .{})) orelse return error.TestUnexpectedResult;
    try weekly.payloadAs(WeeklyReport, a);
}

/// The payload of a record made with this JSON, as SendInvoice reads it.
fn readAs(f: *Fixture, key: []const u8, json: []const u8) !SendInvoice.Payload {
    const request: Store.CreateRequest = .{ .job = "send-invoice", .key = key, .life = @splat(5), .plan = "", .payload = json, .run_at = .{ .after = .fromSeconds(60) } };
    _ = try f.store().create(io, .root, &request, f.options());
    const r = (try f.client.get(io, .root, .of(SendInvoice, key), f.arena.allocator(), .{})) orelse return error.TestUnexpectedResult;
    return r.payloadAs(SendInvoice, f.arena.allocator());
}

test "payloadAs skips unknown fields and takes defaults for missing ones" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    // A newer version wrote a field this one does not know.
    const newer = try readAs(&f, "newer", "{\"order_id\":1,\"amount_cents\":2,\"extra\":true}");
    try testing.expectEqual(@as(u64, 1), newer.order_id);
    try testing.expectEqual(@as(u64, 2), newer.amount_cents);
    try testing.expectEqual(@as(?[]const u8, null), newer.note);
    // An older version wrote no note.
    const older = try readAs(&f, "older", "{\"amount_cents\":7,\"order_id\":9}");
    try testing.expectEqual(@as(u64, 9), older.order_id);
    try testing.expectEqual(@as(?[]const u8, null), older.note);
    // What no version of this type reads.
    try testing.expectError(error.MissingField, readAs(&f, "missing", "{\"order_id\":1}"));
    try testing.expectError(error.UnexpectedToken, readAs(&f, "wrong", "{\"order_id\":true,\"amount_cents\":2}"));
}
