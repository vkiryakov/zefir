//! Tests of scheduler.Client.schedule on a MemoryStore, through a
//! FaultyStore where the calls are counted: the record it makes, the
//! limits it checks before any I/O, the trace of the caller, and the
//! errors of the store.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const scheduler = @import("../root.zig");
const payload = @import("../payload.zig");
const client_fixture = @import("client_fixture.zig");
const SendInvoiceJob = client_fixture.SendInvoiceJob;
const WeeklyReport = client_fixture.WeeklyReport;
const Fixture = client_fixture.Fixture;
const Instant = scheduler.Instant;

const io = testing.io;

const order: scheduler.Ref = .of(SendInvoiceJob, "order-42");

test "schedule creates a record with the payload as JSON" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const scheduled = try f.client.schedule(io, .root, SendInvoiceJob, .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(60) },
        .payload = .{ .order_id = 42, .amount_cents = 1999, .note = "naïve \"quotes\"" },
        .tenant = "acme",
    }, .{});
    try testing.expectEqual(scheduler.Client.Scheduled.created, scheduled);
    const r = try f.record(order);
    try testing.expectEqualStrings("send-invoice", r.job);
    try testing.expectEqualStrings("order-42", r.key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), r.tenant);
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expectEqualStrings("", r.plan);
    try testing.expectEqualStrings("{\"order_id\":42,\"amount_cents\":1999,\"note\":\"naïve \\\"quotes\\\"\"}", r.payload);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(@as(u64, 0), r.fence);
    const back = try payload.decode(SendInvoiceJob, f.arena.allocator(), r.payload);
    try testing.expectEqual(@as(u64, 42), back.order_id);
    try testing.expectEqual(@as(u64, 1999), back.amount_cents);
    try testing.expectEqualDeep(@as(?[]const u8, "naïve \"quotes\""), back.note);

    // A job without Payload keeps the empty object.
    try testing.expectEqual(.created, try f.client.schedule(io, .root, WeeklyReport, .{ .key = "acme", .when = .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) } }, .{}));
    try testing.expectEqualStrings("{}", (try f.record(.of(WeeklyReport, "acme"))).payload);
}

test "schedule again with the same key is existing and changes nothing" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 42, .amount_cents = 1999 } }, .{}));
    const before = try f.record(order);
    try testing.expectEqual(.existing, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .fromSeconds(5) }, .payload = .{ .order_id = 43, .amount_cents = 1 }, .tenant = "acme" }, .{}));
    try testing.expectEqualDeep(before, try f.record(order));
    try testing.expectEqual(@as(u32, 2), f.faulty.calls(io, .create));
}

test "schedule over a finished record is created with a new life" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const old = try f.failed("order-42");
    try testing.expectEqual(scheduler.State.failed, old.state);
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 42, .amount_cents = 5 } }, .{}));
    const r = try f.record(order);
    try testing.expectEqual(scheduler.State.pending, r.state);
    try testing.expect(!std.mem.eql(u8, &old.life, &r.life));
    try testing.expectEqual(@as(u64, 0), r.fence);
    try testing.expectEqual(@as(u32, 0), r.attempt);
    try testing.expectEqual(@as(?scheduler.LastRun, null), r.last);
    try testing.expectEqualStrings("{\"order_id\":42,\"amount_cents\":5,\"note\":null}", r.payload);
}

test "when gives run_at, scheduled_at and plan" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const at: Instant = .fromUtc(2030, 1, 2, 3, 4, 5, .h24);
    _ = try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "at", .when = .{ .at = at }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{});
    var r = try f.record(.of(SendInvoiceJob, "at"));
    try testing.expectEqual(@as(?Instant, at), r.run_at);
    try testing.expectEqual(at, r.scheduled_at);
    try testing.expectEqualStrings("", r.plan);

    // .after counts from the store's clock: between its now before the
    // call and after it.
    var from = f.store().now(io);
    _ = try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "after", .when = .{ .after = .fromSeconds(2) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{});
    var to = f.store().now(io);
    r = try f.record(.of(SendInvoiceJob, "after"));
    try expectWithin(r.run_at, from.unix_ms + 2000, to.unix_ms + 2000);
    try testing.expectEqual(r.run_at, @as(?Instant, r.scheduled_at));
    try testing.expectEqualStrings("", r.plan);

    // A schedule of the calendar starts at its next moment after the
    // store's now; 3:30 AM is 03:30:00 of the 24-hour clock.
    const nightly: scheduler.Schedule = .dailyAt(3, 30, 0, .am);
    from = f.store().now(io);
    _ = try f.client.schedule(io, .root, WeeklyReport, .{ .key = "nightly", .when = .{ .repeat = nightly } }, .{});
    to = f.store().now(io);
    r = try f.record(.of(WeeklyReport, "nightly"));
    try testing.expectEqualStrings("daily 03:30:00", r.plan);
    const first = r.run_at orelse return error.TestUnexpectedResult;
    const earliest = nightly.next(from) orelse return error.TestUnexpectedResult;
    const latest = nightly.next(to) orelse return error.TestUnexpectedResult;
    try testing.expect(first.unix_ms == earliest.unix_ms or first.unix_ms == latest.unix_ms);
    try testing.expectEqual(@as(i64, (3 * 60 + 30) * 60 * 1000), @mod(first.unix_ms, 24 * 60 * 60 * 1000));
    try testing.expectEqual(first, r.scheduled_at);

    // fixedDelay: the first run comes its delay after the store took it.
    from = f.store().now(io);
    _ = try f.client.schedule(io, .root, WeeklyReport, .{ .key = "delay", .when = .{ .repeat = .fixedDelay(.fromSeconds(30)) } }, .{});
    to = f.store().now(io);
    r = try f.record(.of(WeeklyReport, "delay"));
    try testing.expectEqualStrings("delay 30s", r.plan);
    try expectWithin(r.run_at, from.unix_ms + 30_000, to.unix_ms + 30_000);
}

/// `at` is a moment within `[low, high]` in milliseconds.
fn expectWithin(at: ?Instant, low: i64, high: i64) !void {
    const ms = (at orelse return error.TestUnexpectedResult).unix_ms;
    if (ms < low or ms > high) {
        std.debug.print("{d} is not within [{d}, {d}]\n", .{ ms, low, high });
        return error.TestUnexpectedResult;
    }
}

/// `schedule` of SendInvoiceJob that must fail with InvalidArgument and a
/// text that starts with `field`, before any call of the store.
fn expectRefused(f: *Fixture, field: []const u8, request: scheduler.Client.Request(SendInvoiceJob)) !void {
    var d: scheduler.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, f.client.schedule(io, .root, SendInvoiceJob, request, .{ .diagnostics = &d }));
    if (!std.mem.startsWith(u8, d.message(), field)) {
        std.debug.print("\"{s}\" does not start with \"{s}\"\n", .{ d.message(), field });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, .create));
}

test "limits are InvalidArgument before any I/O" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const a = f.arena.allocator();
    const small: SendInvoiceJob.Payload = .{ .order_id = 1, .amount_cents = 1 };
    const soon: scheduler.When = .{ .after = .fromSeconds(60) };

    // Keys and tenants.
    try expectRefused(&f, "key: empty", .{ .key = "", .when = soon, .payload = small });
    try expectRefused(&f, "key: 257 bytes", .{ .key = &@as([257]u8, @splat('k')), .when = soon, .payload = small });
    try expectRefused(&f, "key: it holds a NUL", .{ .key = "order\x0042", .when = soon, .payload = small });
    try expectRefused(&f, "key: not UTF-8", .{ .key = "order-\xc3", .when = soon, .payload = small });
    try expectRefused(&f, "tenant: 129 bytes", .{ .key = "order-42", .when = soon, .payload = small, .tenant = &@as([129]u8, @splat('t')) });

    // The payload: its JSON is at most 64 KiB, and UTF-8.
    const overhead = (try payload.encode(SendInvoiceJob, a, .{ .order_id = 1, .amount_cents = 1, .note = "" })).len;
    const note = try a.alloc(u8, 64 * 1024 + 1 - overhead);
    @memset(note, 'n');
    try expectRefused(&f, "payload: its JSON is 65537 bytes; at most 65536", .{ .key = "order-42", .when = soon, .payload = .{ .order_id = 1, .amount_cents = 1, .note = note } });
    try expectRefused(&f, "payload: a string in it is not UTF-8", .{ .key = "order-42", .when = soon, .payload = .{ .order_id = 1, .amount_cents = 1, .note = "\xff" } });

    // When: the bounds of .after and .at, and schedules that are none.
    try expectRefused(&f, "when: .after is -1s", .{ .key = "order-42", .when = .{ .after = .fromSeconds(-1) }, .payload = small });
    try expectRefused(&f, "when: .after is 101y", .{ .key = "order-42", .when = .{ .after = .fromSeconds(101 * 31_557_600) }, .payload = small });
    try expectRefused(&f, "when: .after is ", .{ .key = "order-42", .when = .{ .after = .max }, .payload = small });
    try expectRefused(&f, "when: .at is Instant.invalid", .{ .key = "order-42", .when = .{ .at = .invalid }, .payload = small });
    var month: u8 = 2;
    _ = &month;
    try expectRefused(&f, "when: .at is Instant.invalid", .{ .key = "order-42", .when = .{ .at = .fromUtc(2026, month, 29, 0, 0, 0, .h24) }, .payload = small });
    try expectRefused(&f, "when: .at is +10000-01-01T00:00:00.000Z", .{ .key = "order-42", .when = .{ .at = .fromUnixMs(253_402_300_800_000) }, .payload = small });
    var hour: u8 = 13;
    _ = &hour;
    try expectRefused(&f, "when: dailyAt(13, 0, 0, .pm): an hour of the 12-hour clock is 1–12", .{ .key = "order-42", .when = .{ .repeat = .dailyAt(hour, 0, 0, .pm) }, .payload = small });
    var expression: []const u8 = "0 0 30 2 *";
    _ = &expression;
    try expectRefused(&f, "when: cron \"0 0 30 2 *\": day 30 never comes in February", .{ .key = "order-42", .when = .{ .repeat = .cron(expression) }, .payload = small });
    try expectRefused(&f, "when: fixedDelay(0ns)", .{ .key = "order-42", .when = .{ .repeat = .fixedDelay(.zero) }, .payload = small });

    // The bounds themselves pass.
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "64-kib", .when = soon, .payload = .{ .order_id = 1, .amount_cents = 1, .note = note[1..] } }, .{}));
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = &@as([256]u8, @splat('k')), .when = .{ .at = .fromUnixMs(253_402_300_799_999) }, .payload = small, .tenant = &@as([128]u8, @splat('t')) }, .{}));
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "100-years", .when = .{ .after = .fromSeconds(3_155_760_000) }, .payload = small }, .{}));

    // A client with a smaller limit.
    var tight: Fixture = undefined;
    tight.init(.{ .max_payload_bytes = 1024 });
    defer tight.deinit();
    try expectRefused(&tight, "payload: its JSON is 1025 bytes; at most 1024", .{ .key = "order-42", .when = soon, .payload = .{ .order_id = 1, .amount_cents = 1, .note = note[0 .. 1025 - overhead] } });
    try testing.expectEqual(.created, try tight.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = soon, .payload = .{ .order_id = 1, .amount_cents = 1, .note = note[0 .. 1024 - overhead] } }, .{}));
}

test "a string that is not UTF-8 is found at any depth of a payload" {
    const Choice = union(enum) { text: []const u8, number: u32 };
    const Nested = struct { tags: []const []const u8, code: [2]u8, inner: ?struct { name: []const u8 }, choice: Choice };
    const good: Nested = .{ .tags = &.{ "a", "é" }, .code = "ok".*, .inner = .{ .name = "x" }, .choice = .{ .text = "y" } };
    try testing.expect(payload.validUtf8(good));
    var bad = good;
    bad.tags = &.{ "a", "\xc3" };
    try testing.expect(!payload.validUtf8(bad));
    bad = good;
    bad.code = .{ 0xff, 0 };
    try testing.expect(!payload.validUtf8(bad));
    bad = good;
    bad.inner = .{ .name = "\xff" };
    try testing.expect(!payload.validUtf8(bad));
    bad = good;
    bad.choice = .{ .text = "\xff" };
    try testing.expect(!payload.validUtf8(bad));
    bad.choice = .{ .number = 0xff };
    try testing.expect(payload.validUtf8(bad));
}

test "no text of the client holds the payload" {
    var f: Fixture = undefined;
    f.init(.{ .max_payload_bytes = 1024 });
    defer f.deinit();
    const marker = "card-4242-4242-4242-4242";
    const parts: [64][]const u8 = @splat(marker);
    const big = try std.mem.concat(f.arena.allocator(), u8, &parts);
    var d: scheduler.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .zero }, .payload = .{ .order_id = 1, .amount_cents = 1, .note = big } }, .{ .diagnostics = &d }));
    try testing.expect(d.message().len > 0);
    try testing.expect(std.mem.find(u8, d.message(), "card") == null);
    d = .{};
    try testing.expectError(error.InvalidArgument, f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .zero }, .payload = .{ .order_id = 1, .amount_cents = 1, .note = marker ++ "\xff" } }, .{ .diagnostics = &d }));
    try testing.expect(d.message().len > 0);
    try testing.expect(std.mem.find(u8, d.message(), "card") == null);
}

test "schedule keeps the caller's traceparent" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    const ctx = core.Context.root.withTrace(.{
        .trace_id = try core.TraceId.parseHex("4bf92f3577b34da6a3ce929d0e0e4736"),
        .span_id = try core.SpanId.parseHex("00f067aa0ba902b7"),
        .flags = .{ .sampled = true },
        .state = .empty,
    });
    _ = try f.client.schedule(io, ctx, SendInvoiceJob, .{ .key = "traced", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{});
    try testing.expectEqualDeep(@as(?[]const u8, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"), (try f.record(.of(SendInvoiceJob, "traced"))).trace);
    _ = try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "untraced", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{});
    try testing.expectEqual(@as(?[]const u8, null), (try f.record(.of(SendInvoiceJob, "untraced"))).trace);
}

test "store errors pass through" {
    var f: Fixture = undefined;
    f.init(.{});
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    f.faulty.failNext(io, .create, error.Unavailable, 1);
    try testing.expectError(error.Unavailable, f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("testing.FaultyStore: create failed on demand with error.Unavailable", d.message());
    try testing.expectEqual(.created, try f.client.schedule(io, .root, SendInvoiceJob, .{ .key = "order-42", .when = .{ .after = .fromSeconds(60) }, .payload = .{ .order_id = 1, .amount_cents = 1 } }, .{}));
}
