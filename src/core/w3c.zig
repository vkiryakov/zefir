//! W3C Trace Context headers, `traceparent` and `tracestate`: parsing and
//! formatting for any transport (HTTP headers, RPC metadata, message
//! properties). Follows W3C Trace Context Level 1 plus two Level 2 additions
//! the official test suite requires: the `random` flag and the tracestate
//! key grammar.
//!
//! A receiving adapter:
//!
//! ```zig
//! const trace: ?core.TraceContext = if (core.w3c.parseTraceparent(traceparent)) |parsed| blk: {
//!     var with_state = parsed;
//!     // A bad tracestate is dropped; the traceparent stays.
//!     with_state.state = core.w3c.parseTracestate(tracestate) catch .empty;
//!     break :blk with_state;
//! } else |_| null; // A bad traceparent restarts the trace; tracestate is not parsed.
//! ```
//!
//! Transports keep these rules:
//! - header names are case-insensitive;
//! - two or more `traceparent` fields are invalid;
//! - several `tracestate` fields are joined with `,` in order;
//! - a `tracestate` without a valid `traceparent` is dropped;
//! - an empty `TraceState` is not sent.

const std = @import("std");
const TraceState = @import("trace.zig").TraceState;
const TraceContext = @import("trace.zig").TraceContext;
const TraceFlags = @import("trace.zig").TraceFlags;
const TraceId = @import("trace.zig").TraceId;
const SpanId = @import("trace.zig").SpanId;

/// At most this many non-empty list members in a tracestate.
const max_tracestate_members = 32;

/// Optional whitespace around header values and tracestate members.
const ows = " \t";

/// The length of a version-00 traceparent, the only version written.
pub const traceparent_len = 55;

/// Parses a traceparent value. Versions above 00 are read the W3C way: the
/// first four fields are used and anything after them is ignored.
pub fn parseTraceparent(value: []const u8) error{InvalidTraceparent}!TraceContext {
    const header = std.mem.trim(u8, value, ows);
    if (header.len < traceparent_len) return error.InvalidTraceparent;
    if (header[2] != '-' or header[35] != '-' or header[52] != '-') return error.InvalidTraceparent;

    const version = lowerHexByte(header[0..2]) orelse return error.InvalidTraceparent;
    if (version == 0xff) return error.InvalidTraceparent;
    if (version == 0x00) {
        if (header.len != traceparent_len) return error.InvalidTraceparent;
    } else if (header.len > traceparent_len and header[traceparent_len] != '-') {
        return error.InvalidTraceparent;
    }

    const trace_id = TraceId.parseHex(header[3..35]) catch return error.InvalidTraceparent;
    const span_id = SpanId.parseHex(header[36..52]) catch return error.InvalidTraceparent;
    var flags: TraceFlags = .fromByte(lowerHexByte(header[53..55]) orelse return error.InvalidTraceparent);
    // Of a newer version's flags, only the bits this version defines are read.
    if (version != 0x00) flags.reserved = 0;

    return .{ .trace_id = trace_id, .span_id = span_id, .flags = flags, .state = .empty, .is_remote = true };
}

/// Writes `trace` as a version-00 traceparent into `out` and returns it.
/// Only the `sampled` and `random` flags are sent; unknown bits are zeroed.
pub fn formatTraceparent(trace: TraceContext, out: *[traceparent_len]u8) []const u8 {
    std.debug.assert(trace.isValid());
    const flags: TraceFlags = .{ .sampled = trace.flags.sampled, .random = trace.flags.random };
    @memcpy(out[0..3], "00-");
    out[3..35].* = trace.trace_id.toHex();
    out[35] = '-';
    out[36..52].* = trace.span_id.toHex();
    out[52] = '-';
    out[53..55].* = std.fmt.hex(flags.toByte());
    return out;
}

/// Validates a tracestate value (several header fields joined with `,`) and
/// returns it as a `TraceState` that borrows `value`. Duplicate keys are
/// allowed and kept; any other invalid member makes the whole value invalid.
pub fn parseTracestate(value: []const u8) error{InvalidTracestate}!TraceState {
    const header = std.mem.trim(u8, value, ows);
    var members: usize = 0;
    var rest = header;
    while (true) {
        const comma = std.mem.findScalar(u8, rest, ',');
        const member = std.mem.trim(u8, rest[0 .. comma orelse rest.len], ows);
        if (member.len != 0) {
            members += 1;
            if (members > max_tracestate_members) return error.InvalidTracestate;
            if (!isValidMember(member)) return error.InvalidTracestate;
        }
        rest = rest[(comma orelse break) + 1 ..];
    }
    if (members == 0) return .empty;
    return .{ .header = header };
}

fn lowerHexByte(hex: *const [2]u8) ?u8 {
    const high = lowerHexDigit(hex[0]) orelse return null;
    const low = lowerHexDigit(hex[1]) orelse return null;
    return high << 4 | low;
}

fn lowerHexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

fn isValidMember(member: []const u8) bool {
    const eq = std.mem.findScalar(u8, member, '=') orelse return false;
    return isValidKey(member[0..eq]) and isValidValue(member[eq + 1 ..]);
}

/// Level 2 key: a lowercase letter or digit, then up to 255 of `a-z0-9_-*/@`.
fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 256) return false;
    switch (key[0]) {
        'a'...'z', '0'...'9' => {},
        else => return false,
    }
    for (key[1..]) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-', '*', '/', '@' => {},
        else => return false,
    };
    return true;
}

/// 1 to 256 printable ASCII characters except `,` and `=`, not ending in a
/// space. Leading spaces belong to the value.
fn isValidValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    if (value[value.len - 1] == ' ') return false;
    for (value) |c| switch (c) {
        0x20...0x2b, 0x2d...0x3c, 0x3e...0x7e => {},
        else => return false,
    };
    return true;
}

// Vectors marked with a `test_*` name come from the official W3C test suite
// (w3c/trace-context@acab820, test/test.py). Several header fields are
// joined with "," as a transport would. HTTP-level cases (header names,
// repeated requests) belong to transports.

const valid_parent = "00-12345678901234567890123456789012-1234567890123456-01";

test "traceparent: continued traces" {
    const continued = [_][]const u8{
        valid_parent, // test_traceparent_included_tracestate_missing
        " " ++ valid_parent, // test_traceparent_ows_handling a-e
        "\t" ++ valid_parent,
        valid_parent ++ " ",
        valid_parent ++ "\t",
        "\t " ++ valid_parent ++ " \t",
        "cc-12345678901234567890123456789012-1234567890123456-01", // test_traceparent_version_0xcc a, b
        "cc-12345678901234567890123456789012-1234567890123456-01-what-the-future-will-be-like",
    };
    for (continued) |value| {
        const trace = try parseTraceparent(value);
        try std.testing.expectEqualStrings("12345678901234567890123456789012", &trace.trace_id.toHex());
        try std.testing.expectEqualStrings("1234567890123456", &trace.span_id.toHex());
        try std.testing.expect(trace.flags.sampled);
        try std.testing.expect(trace.is_remote);
        try std.testing.expect(trace.state.isEmpty());
    }
}

test "traceparent: restarted traces" {
    const invalid = [_][]const u8{
        valid_parent ++ ".", // test_traceparent_version_0x00 a, b
        valid_parent ++ "-what-the-future-will-be-like",
        "cc-12345678901234567890123456789012-1234567890123456-01.what-the-future-will-be-like", // test_traceparent_version_0xcc c
        "ff-12345678901234567890123456789012-1234567890123456-01", // test_traceparent_version_0xff
        ".0-12345678901234567890123456789012-1234567890123456-01", // test_traceparent_version_illegal_characters
        "0.-12345678901234567890123456789012-1234567890123456-01",
        "000-12345678901234567890123456789012-1234567890123456-01", // test_traceparent_version_too_long
        "0000-12345678901234567890123456789012-1234567890123456-01",
        "0-12345678901234567890123456789012-1234567890123456-01", // test_traceparent_version_too_short
        "00-00000000000000000000000000000000-1234567890123456-01", // test_traceparent_trace_id_all_zero
        "00-.2345678901234567890123456789012-1234567890123456-01", // test_traceparent_trace_id_illegal_characters
        "00-1234567890123456789012345678901.-1234567890123456-01",
        "00-123456789012345678901234567890123-1234567890123456-01", // test_traceparent_trace_id_too_long
        "00-1234567890123456789012345678901-1234567890123456-01", // test_traceparent_trace_id_too_short
        "00-12345678901234567890123456789012-0000000000000000-01", // test_traceparent_parent_id_all_zero
        "00-12345678901234567890123456789012-.234567890123456-01", // test_traceparent_parent_id_illegal_characters
        "00-12345678901234567890123456789012-123456789012345.-01",
        "00-12345678901234567890123456789012-12345678901234567-01", // test_traceparent_parent_id_too_long
        "00-12345678901234567890123456789012-123456789012345-01", // test_traceparent_parent_id_too_short
        "00-12345678901234567890123456789012-1234567890123456-.0", // test_traceparent_trace_flags_illegal_characters
        "00-12345678901234567890123456789012-1234567890123456-0.",
        "00-12345678901234567890123456789012-1234567890123456-001", // test_traceparent_trace_flags_too_long
        "00-12345678901234567890123456789012-1234567890123456-1", // test_traceparent_trace_flags_too_short
        // test_traceparent_duplicated: two fields joined by a transport.
        "00-12345678901234567890123456789011-1234567890123456-01,00-12345678901234567890123456789012-1234567890123456-01",
        // Not covered by the suite.
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01", // uppercase hex
        "CC-12345678901234567890123456789012-1234567890123456-01", // uppercase version
        "cc-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", // uppercase in a newer version
        valid_parent ++ "-", // a lone trailing dash on version 00
        "00x12345678901234567890123456789012-1234567890123456-01", // a wrong delimiter after the version
        "00-12345678901234567890123456789012x1234567890123456-01", // after the trace-id
        "00-12345678901234567890123456789012-1234567890123456x01", // after the parent-id
        "cc-12345678901234567890123456789012-1234567890123456x01", // after the parent-id in a newer version
        "cc-00000000000000000000000000000000-1234567890123456-01", // zero trace-id in a newer version
        valid_parent ++ "\r\n", // CR LF is not whitespace
        valid_parent ++ "\x00",
        "",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidTraceparent, parseTraceparent(value));
    }
}

test "traceparent: flags" {
    // test_propagates_random_flag
    const random = try parseTraceparent("00-12345678901234567890123456789012-1234567890123456-02");
    try std.testing.expect(random.flags.random);
    try std.testing.expect(!random.flags.sampled);

    // Unknown bits of version 00 are kept but never sent.
    const reserved = try parseTraceparent("00-12345678901234567890123456789012-1234567890123456-09");
    try std.testing.expect(reserved.flags.sampled);
    try std.testing.expectEqual(@as(u6, 0b10), reserved.flags.reserved);
    var out: [traceparent_len]u8 = undefined;
    try std.testing.expectEqualStrings(valid_parent, formatTraceparent(reserved, &out));

    // Of a newer version's flags only sampled and random are read.
    const newer = try parseTraceparent("cc-12345678901234567890123456789012-1234567890123456-ff");
    try std.testing.expectEqual(@as(u8, 0x03), newer.flags.toByte());
}

test "traceparent: round trip and downgrade to version 00" {
    const canonical = [_][]const u8{
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-02",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03",
    };
    var out: [traceparent_len]u8 = undefined;
    for (canonical) |value| {
        try std.testing.expectEqualStrings(value, formatTraceparent(try parseTraceparent(value), &out));
    }
    const newer = try parseTraceparent("cc-12345678901234567890123456789012-1234567890123456-01-what-the-future-will-be-like");
    try std.testing.expectEqualStrings(valid_parent, formatTraceparent(newer, &out));
}

const z256: *const [256]u8 = &@splat('z');
const z257: *const [257]u8 = &@splat('z');
const t241: *const [241]u8 = &@splat('t');
const t242: *const [242]u8 = &@splat('t');
const v14: *const [14]u8 = &@splat('v');
const v15: *const [15]u8 = &@splat('v');
const x256: *const [256]u8 = &@splat('x');
const x257: *const [257]u8 = &@splat('x');
const all_value_chars = " !\"#$%&'()*+-./0123456789:;<>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

/// "bar01=01,bar02=02,...", `n` members.
fn barMembers(comptime n: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var text: []const u8 = "";
    inline for (1..n + 1) |i| {
        text = text ++ (if (i == 1) "" else ",") ++ std.fmt.comptimePrint("bar{d:0>2}={d:0>2}", .{ i, i });
    }
    return text;
}

test "tracestate: kept" {
    const Case = struct { value: []const u8, key: []const u8, expected: []const u8 };
    const kept = [_]Case{
        .{ .value = "foo=1,bar=2", .key = "bar", .expected = "2" }, // test_tracestate_included_traceparent_included
        .{ .value = "foo=1,", .key = "foo", .expected = "1" }, // test_tracestate_empty_header b, c
        .{ .value = ",foo=1", .key = "foo", .expected = "1" },
        .{ .value = "foo=1,bar=2,rojo=1,congo=2,baz=3", .key = "baz", .expected = "3" }, // test_tracestate_multiple_headers_different_keys
        .{ .value = "foo=1,foo=1", .key = "foo", .expected = "1" }, // test_tracestate_duplicated_keys a-d
        .{ .value = "foo=1,foo=2", .key = "foo", .expected = "1" },
        .{ .value = "abcdefghijklmnopqrstuvwxyz0123456789_-*/=" ++ all_value_chars, .key = "abcdefghijklmnopqrstuvwxyz0123456789_-*/", .expected = all_value_chars }, // test_tracestate_all_allowed_characters a, b
        .{ .value = "abcdefghijklmnopqrstuvwxyz0123456789_-*/@a-z0-9_-*/=" ++ all_value_chars, .key = "abcdefghijklmnopqrstuvwxyz0123456789_-*/@a-z0-9_-*/", .expected = all_value_chars },
        .{ .value = "foo=1 \t , \t bar=2, \t baz=3", .key = "bar", .expected = "2" }, // test_tracestate_ows_handling a-g
        .{ .value = "foo=1\t \t,\t \tbar=2,\t \tbaz=3", .key = "baz", .expected = "3" },
        .{ .value = " foo=1", .key = "foo", .expected = "1" },
        .{ .value = "\tfoo=1", .key = "foo", .expected = "1" },
        .{ .value = "foo=1 ", .key = "foo", .expected = "1" },
        .{ .value = "foo=1\t", .key = "foo", .expected = "1" },
        .{ .value = "\t foo=1 \t", .key = "foo", .expected = "1" },
        .{ .value = "foo@=1,bar=2", .key = "foo@", .expected = "1" }, // test_tracestate_key_illegal_vendor_format a, c, d
        .{ .value = "foo@@bar=1,bar=2", .key = "bar", .expected = "2" },
        .{ .value = "foo@bar@baz=1,bar=2", .key = "foo@bar@baz", .expected = "1" },
        .{ .value = comptime barMembers(32), .key = "bar01", .expected = "01" }, // test_tracestate_member_count_limit a
        .{ .value = "foo=1," ++ z256 ++ "=1", .key = "foo", .expected = "1" }, // test_tracestate_key_length_limit a, c, d, e
        .{ .value = "foo=1," ++ t241 ++ "@" ++ v14 ++ "=1", .key = "foo", .expected = "1" },
        .{ .value = "foo=1," ++ t242 ++ "@v=1", .key = "foo", .expected = "1" },
        .{ .value = "foo=1,t@" ++ v15 ++ "=1", .key = "foo", .expected = "1" },
        // Not covered by the suite.
        .{ .value = "foo=1, ,bar=2", .key = "bar", .expected = "2" }, // a whitespace-only member
        .{ .value = "1abc=1", .key = "1abc", .expected = "1" }, // a key starting with a digit
        .{ .value = "foo=" ++ x256, .key = "foo", .expected = x256 }, // the longest value
        .{ .value = comptime barMembers(32) ++ ",", .key = "bar32", .expected = "32" }, // empty members do not count
    };
    for (kept) |case| {
        const state = try parseTracestate(case.value);
        try std.testing.expectEqualStrings(case.expected, state.get(case.key).?);
    }
}

test "tracestate: dropped" {
    const dropped = [_][]const u8{
        "foo =1", // test_tracestate_key_illegal_characters a-c
        "FOO=1",
        "foo.bar=1",
        "@foo=1,bar=2", // test_tracestate_key_illegal_vendor_format b
        comptime barMembers(33), // test_tracestate_member_count_limit b
        "foo=1," ++ z257 ++ "=1", // test_tracestate_key_length_limit b
        "foo=bar=baz", // test_tracestate_value_illegal_characters a, b
        "foo=,bar=3",
        // Not covered by the suite.
        "foo=" ++ x257, // value too long
        "foo=a\tb", // a tab inside a value
        "foo=a\x7fb", // DEL, just above the value range
        "foo=a\x1fb", // just below the value range
        "foo=\xc3\xa9", // non-ASCII
        "Foo=1", // an uppercase first character of a key
        "fOO=1", // an uppercase character later in a key
        "_foo=1", // a key starting with a character allowed only later
        "=1", // empty key
        "foo", // no value
    };
    for (dropped) |value| {
        try std.testing.expectError(error.InvalidTracestate, parseTracestate(value));
    }
}

test "tracestate: forwarded as received, without outer whitespace" {
    const state = try parseTracestate(" \trojo=00f067aa0ba902b7, congo=t61rcWkgMzE\t ");
    try std.testing.expectEqualStrings("rojo=00f067aa0ba902b7, congo=t61rcWkgMzE", state.header);

    // test_tracestate_empty_header a: no entries means an empty state.
    try std.testing.expect((try parseTracestate("")).isEmpty());
    try std.testing.expect((try parseTracestate(" , ,\t")).isEmpty());
}

test "tracestate: a long run of empty members is accepted" {
    const commas: [100_000]u8 = @splat(',');
    try std.testing.expect((try parseTracestate(&commas)).isEmpty());
}
