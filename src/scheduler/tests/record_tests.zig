//! Tests of the record types and of the rules of names, keys and tenants.

const std = @import("std");
const testing = std.testing;
const record = @import("../record.zig");

test "job names follow the rule of names" {
    for ([_][]const u8{ "send-invoice", "a", "0.v2_x", &@as([64]u8, @splat('a')) }) |name| {
        try testing.expect(record.validJobName(name));
    }
    for ([_][]const u8{ "", &@as([65]u8, @splat('a')), "Send", "-x", ".x", "_x", "a/b", "a b", "ж" }) |name| {
        try testing.expect(!record.validJobName(name));
    }
}

test "keys and tenants are UTF-8 without NUL" {
    // 256 bytes: "order/" and 125 times "ж", 2 bytes each.
    var key: [257]u8 = undefined;
    @memcpy(key[0..6], "order/");
    for (0..125) |i| @memcpy(key[6 + 2 * i ..][0..2], "ж");
    try testing.expect(record.validKey(key[0..256]));
    key[256] = 'x';
    try testing.expect(!record.validKey(&key));
    for ([_][]const u8{ "", "a\x00b", "\xff", "ж"[0..1] }) |bad| {
        try testing.expect(!record.validKey(bad));
        try testing.expect(!record.validTenant(bad));
    }
    try testing.expect(record.validKey("$set"));
    try testing.expect(record.validTenant(&@as([128]u8, @splat('t'))));
    try testing.expect(!record.validTenant(&@as([129]u8, @splat('t'))));
}

test "a record and a run hold what a store keeps" {
    const life: record.Life = @splat(7);
    const r: record.Record = .{
        .job = "send-invoice",
        .key = "order-42",
        .tenant = null,
        .state = .pending,
        .plan = "",
        .payload = "{}",
        .scheduled_at = .fromUnixMs(1_000),
        .run_at = .fromUnixMs(1_000),
        .attempt = 0,
        .fence = 0,
        .revision = 0,
        .pause_requested = false,
        .owner = null,
        .claimed_at = null,
        .lease_until = null,
        .last = null,
        .created_at = .fromUnixMs(500),
        .updated_at = .fromUnixMs(500),
        .finished_at = null,
        .expires_at = null,
        .trace = null,
        .life = life,
        .unreadable_since = null,
    };
    try testing.expectEqual(record.State.pending, r.state);
    const run: record.Run = .{
        .job = r.job,
        .key = r.key,
        .tenant = null,
        .life = life,
        .fence = 1,
        .attempt = 1,
        .scheduled_at = r.scheduled_at,
        .started_at = .fromUnixMs(1_001),
        .finished_at = .fromUnixMs(1_002),
        .outcome = .abandoned,
        .error_name = null,
        .instance = "shop/7f3a",
        .expires_at = null,
    };
    try testing.expectEqual(record.RunOutcome.abandoned, run.outcome);
    const keep: record.Retention = .{ .keep_for = .fromSeconds(30) };
    try testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), keep.keep_for.nanoseconds);
    const page: record.Page = .{};
    try testing.expectEqual(@as(u32, 100), page.limit);
    try testing.expectEqual(@as(?[]const u8, null), page.after);
}
