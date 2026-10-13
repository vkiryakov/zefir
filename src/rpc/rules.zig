//! The rules for route names and metadata that the engine checks, the same
//! on every transport. Internal to the module.

const std = @import("std");
const model = @import("model.zig");
const Entry = model.Metadata.Entry;

/// The longest service name, method name or metadata key, in bytes.
pub const max_name_bytes = 64;

/// The longest `zefir-correlation-id` value, in bytes.
pub const max_correlation_id_bytes = 128;

/// The keys only the engine writes. Each may appear once in a request and
/// never in a response.
pub const reserved_keys = [_][]const u8{ "authorization", "traceparent", "tracestate", "zefir-correlation-id" };

/// Keys that start with this prefix belong to the engine.
pub const engine_prefix = "zefir-";

/// Whether `name` can be a service or method name: 1 to 64 characters from
/// `[A-Za-z0-9_-]`.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Service and method names valid and the version above 0.
pub fn validateRoute(route: model.Route) error{InvalidRoute}!void {
    if (!isValidName(route.service) or !isValidName(route.method) or route.version == 0) return error.InvalidRoute;
}

/// Whether `key` can be a metadata key: 1 to 64 characters from
/// `[a-z0-9_-]`. An upper-case letter is invalid; nothing is lower-cased.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_name_bytes) return false;
    for (key) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether `value` can be a metadata value: printable ASCII (0x20–0x7E)
/// without a space at either end. The empty value is valid.
pub fn isValidValue(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value[0] == ' ' or value[value.len - 1] == ' ') return false;
    for (value) |c| if (c < 0x20 or c > 0x7E) return false;
    return true;
}

/// Whether `key` is one of `reserved_keys`.
pub fn isReserved(key: []const u8) bool {
    return reservedIndex(key) != null;
}

fn reservedIndex(key: []const u8) ?usize {
    for (reserved_keys, 0..) |reserved, i| {
        if (std.mem.eql(u8, key, reserved)) return i;
    }
    return null;
}

/// The size of metadata as the limit `max_metadata_bytes` counts it:
/// 2 + the sum of (3 + key length + value length) over the entries.
pub fn metadataBytes(entries: []const Entry) usize {
    // Saturating: the entries of a hostile list may all point at one large
    // value.
    var total: usize = 2;
    for (entries) |entry| total = total +| 3 +| entry.key.len +| entry.value.len;
    return total;
}

/// The limits that metadata must fit in.
pub const MetadataLimits = struct {
    max_entries: u32,
    max_bytes: u32,
};

/// What is wrong with metadata. `too_large` becomes `resource_exhausted`,
/// `invalid` becomes `invalid_argument`.
pub const Problem = enum { invalid, too_large };

/// Checks the metadata of an incoming request at admission; null when it is
/// fine. The limits come first: metadata both too large and invalid is
/// `too_large`. Invalid: a key or value against the rules, a reserved key
/// that repeats (even with the same value), a `zefir-*` key the engine does
/// not know, a `zefir-correlation-id` longer than 128 bytes. Other keys may
/// repeat.
pub fn checkRequestMetadata(entries: []const Entry, limits: MetadataLimits) ?Problem {
    if (exceeds(entries, limits)) return .too_large;
    var seen: [reserved_keys.len]bool = @splat(false);
    for (entries) |entry| {
        if (!isValidKey(entry.key) or !isValidValue(entry.value)) return .invalid;
        if (reservedIndex(entry.key)) |i| {
            if (seen[i]) return .invalid;
            seen[i] = true;
            if (i == correlation_index and entry.value.len > max_correlation_id_bytes) return .invalid;
        } else if (std.mem.startsWith(u8, entry.key, engine_prefix)) {
            return .invalid;
        }
    }
    return null;
}

const correlation_index = reservedIndex("zefir-correlation-id").?;

fn exceeds(entries: []const Entry, limits: MetadataLimits) bool {
    return entries.len > limits.max_entries or metadataBytes(entries) > limits.max_bytes;
}

/// Valid keys and values, none of them the engine's.
fn checkOwnEntries(entries: []const Entry) ?Problem {
    for (entries) |entry| {
        if (!isValidKey(entry.key) or !isValidValue(entry.value)) return .invalid;
        if (isReserved(entry.key) or std.mem.startsWith(u8, entry.key, engine_prefix)) return .invalid;
    }
    return null;
}

/// Checks the metadata a client application passes to a call, before it is
/// sent; null when it is fine. Besides the key and value rules, reserved and
/// `zefir-*` keys are invalid: only the engine writes them. The limits are
/// the server's to check.
pub fn checkUserMetadata(entries: []const Entry) ?Problem {
    return checkOwnEntries(entries);
}

/// Checks the metadata of a response; null when it is fine. The rules of a
/// request apply, except that reserved and `zefir-*` keys are invalid in a
/// response. The limits come first, as in `checkRequestMetadata`.
pub fn checkResponseMetadata(entries: []const Entry, limits: MetadataLimits) ?Problem {
    if (exceeds(entries, limits)) return .too_large;
    return checkOwnEntries(entries);
}

const testing = std.testing;
const default_limits: MetadataLimits = .{ .max_entries = 64, .max_bytes = 16 * 1024 };

test "names: [A-Za-z0-9_-], 1 to 64 characters" {
    const name64: [64]u8 = @splat('n');
    const name65: [65]u8 = @splat('n');
    for ([_][]const u8{ "users", "getUser", "get_user", "get-user", "A", "0", "_", &name64 }) |name| {
        try testing.expect(isValidName(name));
    }
    for ([_][]const u8{ "", &name65, "get.user", "get user", "users/v1", "ü", "a\x00", "*" }) |name| {
        try testing.expect(!isValidName(name));
    }
}

test "a route needs valid names and a version above 0" {
    try validateRoute(.{ .service = "users", .version = 1, .method = "getUser" });
    try validateRoute(.{ .service = "users", .version = std.math.maxInt(u16), .method = "getUser" });
    try testing.expectError(error.InvalidRoute, validateRoute(.{ .service = "users", .version = 0, .method = "getUser" }));
    try testing.expectError(error.InvalidRoute, validateRoute(.{ .service = "user.s", .version = 1, .method = "getUser" }));
    try testing.expectError(error.InvalidRoute, validateRoute(.{ .service = "users", .version = 1, .method = "" }));
}

test "keys: [a-z0-9_-], 1 to 64 characters, no upper case" {
    const key64: [64]u8 = @splat('k');
    const key65: [65]u8 = @splat('k');
    for ([_][]const u8{ "x", "idempotency-key", "a_b", "0-9", "traceparent", &key64 }) |key| {
        try testing.expect(isValidKey(key));
    }
    for ([_][]const u8{ "", "Authorization", "idempotencyKey", &key65, "a.b", "a b", "key:", "ключ" }) |key| {
        try testing.expect(!isValidKey(key));
    }
}

test "values: printable ASCII without a space at either end" {
    for ([_][]const u8{ "", "Bearer abc", "a b", "!~", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }) |value| {
        try testing.expect(isValidValue(value));
    }
    for ([_][]const u8{ "\x1f", "\x7f", " leading", "trailing ", " ", "tab\there", "é", "line\n" }) |value| {
        try testing.expect(!isValidValue(value));
    }
}

test "reserved keys" {
    for (reserved_keys) |key| try testing.expect(isReserved(key));
    try testing.expect(!isReserved("zefir-foo"));
    try testing.expect(!isReserved("Authorization"));
    try testing.expect(!isReserved("x-authorization"));
}

test "metadata bytes: 2 plus 3 and the lengths per entry" {
    try testing.expectEqual(@as(usize, 2), metadataBytes(&.{}));
    try testing.expectEqual(@as(usize, 10), metadataBytes(&.{.{ .key = "ab", .value = "cde" }}));
    try testing.expectEqual(@as(usize, 2 + 4 + 5), metadataBytes(&.{ .{ .key = "a", .value = "" }, .{ .key = "b", .value = "c" } }));
}

test "request metadata: valid lists" {
    try testing.expectEqual(@as(?Problem, null), checkRequestMetadata(&.{}, default_limits));
    try testing.expectEqual(@as(?Problem, null), checkRequestMetadata(&.{
        .{ .key = "authorization", .value = "Bearer abc" },
        .{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" },
        .{ .key = "tracestate", .value = "" },
        .{ .key = "zefir-correlation-id", .value = "order-42" },
        // Other keys may repeat, in order.
        .{ .key = "x-tag", .value = "a" },
        .{ .key = "x-tag", .value = "b" },
    }, default_limits));
}

test "request metadata: invalid keys, values and reserved repeats" {
    const correlation128: [128]u8 = @splat('c');
    const correlation129: [129]u8 = @splat('c');
    try testing.expectEqual(@as(?Problem, null), checkRequestMetadata(&.{.{ .key = "zefir-correlation-id", .value = &correlation128 }}, default_limits));

    const invalid = [_][]const Entry{
        &.{.{ .key = "Authorization", .value = "x" }},
        &.{.{ .key = "x", .value = " padded" }},
        &.{.{ .key = "", .value = "x" }},
        &.{.{ .key = "x", .value = "\x7f" }},
        // A reserved key twice, even with the same value.
        &.{ .{ .key = "authorization", .value = "Bearer abc" }, .{ .key = "authorization", .value = "Bearer abc" } },
        &.{ .{ .key = "tracestate", .value = "a=1" }, .{ .key = "x", .value = "" }, .{ .key = "tracestate", .value = "b=2" } },
        // zefir-* keys other than the ones the engine knows.
        &.{.{ .key = "zefir-foo", .value = "1" }},
        &.{.{ .key = "zefir-correlation-id", .value = &correlation129 }},
    };
    for (invalid) |entries| {
        try testing.expectEqual(@as(?Problem, .invalid), checkRequestMetadata(entries, default_limits));
    }
}

test "request metadata: exactly at the limits passes, one more does not" {
    var entries: [65]Entry = @splat(.{ .key = "k", .value = "v" });
    try testing.expectEqual(@as(?Problem, null), checkRequestMetadata(entries[0..64], default_limits));
    try testing.expectEqual(@as(?Problem, .too_large), checkRequestMetadata(&entries, default_limits));

    // 2 + 3 + 1 + 16378 = 16 KiB.
    const value: [16_379]u8 = @splat('v');
    try testing.expectEqual(@as(usize, 16 * 1024), metadataBytes(&.{.{ .key = "k", .value = value[0..16_378] }}));
    try testing.expectEqual(@as(?Problem, null), checkRequestMetadata(&.{.{ .key = "k", .value = value[0..16_378] }}, default_limits));
    try testing.expectEqual(@as(?Problem, .too_large), checkRequestMetadata(&.{.{ .key = "k", .value = &value }}, default_limits));

    // The limits come first.
    entries[0] = .{ .key = "Bad", .value = "v" };
    try testing.expectEqual(@as(?Problem, .too_large), checkRequestMetadata(&entries, default_limits));
    try testing.expectEqual(@as(?Problem, .invalid), checkRequestMetadata(entries[0..64], default_limits));
}

test "user metadata: reserved and zefir-* keys are the engine's" {
    try testing.expectEqual(@as(?Problem, null), checkUserMetadata(&.{}));
    try testing.expectEqual(@as(?Problem, null), checkUserMetadata(&.{
        .{ .key = "idempotency-key", .value = "7f3e" },
        .{ .key = "x-tag", .value = "a" },
        .{ .key = "x-tag", .value = "b" },
    }));
    for (reserved_keys) |key| {
        try testing.expectEqual(@as(?Problem, .invalid), checkUserMetadata(&.{.{ .key = key, .value = "x" }}));
    }
    try testing.expectEqual(@as(?Problem, .invalid), checkUserMetadata(&.{.{ .key = "zefir-foo", .value = "x" }}));
    try testing.expectEqual(@as(?Problem, .invalid), checkUserMetadata(&.{.{ .key = "Upper", .value = "x" }}));
    try testing.expectEqual(@as(?Problem, .invalid), checkUserMetadata(&.{.{ .key = "x", .value = "end " }}));
}

test "response metadata: the request rules without reserved keys" {
    try testing.expectEqual(@as(?Problem, null), checkResponseMetadata(&.{}, default_limits));
    try testing.expectEqual(@as(?Problem, null), checkResponseMetadata(&.{
        .{ .key = "x-cache", .value = "hit" },
        .{ .key = "x-cache", .value = "miss" },
    }, default_limits));
    for (reserved_keys) |key| {
        try testing.expectEqual(@as(?Problem, .invalid), checkResponseMetadata(&.{.{ .key = key, .value = "x" }}, default_limits));
    }
    try testing.expectEqual(@as(?Problem, .invalid), checkResponseMetadata(&.{.{ .key = "zefir-foo", .value = "x" }}, default_limits));
    try testing.expectEqual(@as(?Problem, .invalid), checkResponseMetadata(&.{.{ .key = "x", .value = "\x1f" }}, default_limits));

    const entries: [65]Entry = @splat(.{ .key = "k", .value = "v" });
    try testing.expectEqual(@as(?Problem, null), checkResponseMetadata(entries[0..64], default_limits));
    try testing.expectEqual(@as(?Problem, .too_large), checkResponseMetadata(&entries, default_limits));
    try testing.expectEqual(@as(?Problem, .too_large), checkResponseMetadata(&.{.{ .key = "k", .value = "vv" }}, .{ .max_entries = 1, .max_bytes = 7 }));
}
