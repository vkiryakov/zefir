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

/// At most this many non-empty list members in a tracestate.
const max_tracestate_members = 32;

/// Optional whitespace around header values and tracestate members.
const ows = " \t";

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
        "foo=\xc3\xa9", // non-ASCII
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
