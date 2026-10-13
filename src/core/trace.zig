//! Distributed tracing identity in W3C Trace Context terms: trace-id,
//! span-id, trace-flags and tracestate. Core only carries the identity; it
//! creates no spans, samples nothing and exports nothing.

const std = @import("std");

/// A W3C trace-id: 16 bytes, not all zero.
///
/// Build it with `fromBytes` or `parseHex`. A struct literal can hold the
/// invalid all-zero id; `Context.withTrace`, `TraceContext.child` and
/// `w3c.formatTraceparent` assert that ids are valid.
pub const TraceId = struct {
    bytes: [16]u8,

    /// The id from 16 bytes, for example drawn with `io.random`; all zero is
    /// invalid.
    pub fn fromBytes(bytes: [16]u8) error{InvalidTraceId}!TraceId {
        const id: TraceId = .{ .bytes = bytes };
        if (!id.isValid()) return error.InvalidTraceId;
        return id;
    }

    /// Exactly 32 lowercase hex digits, not all zero.
    pub fn parseHex(hex: []const u8) error{InvalidTraceId}!TraceId {
        var bytes: [16]u8 = undefined;
        if (!decodeLowerHex(&bytes, hex)) return error.InvalidTraceId;
        return fromBytes(bytes);
    }

    /// The id as lowercase hex, as it appears in a traceparent.
    pub fn toHex(id: TraceId) [32]u8 {
        return std.fmt.bytesToHex(id.bytes, .lower);
    }

    /// Whether the id is not all zero.
    pub fn isValid(id: TraceId) bool {
        return !std.mem.allEqual(u8, &id.bytes, 0);
    }

    /// Prints the id as lowercase hex with `{f}`.
    pub fn format(id: TraceId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&id.toHex());
    }
};

/// A W3C span-id (the parent-id of a traceparent): 8 bytes, not all zero.
///
/// Build it with `fromBytes` or `parseHex`. A struct literal can hold the
/// invalid all-zero id; `Context.withTrace`, `TraceContext.child` and
/// `w3c.formatTraceparent` assert that ids are valid.
pub const SpanId = struct {
    bytes: [8]u8,

    /// The id from 8 bytes, for example drawn with `io.random`; all zero is
    /// invalid.
    pub fn fromBytes(bytes: [8]u8) error{InvalidSpanId}!SpanId {
        const id: SpanId = .{ .bytes = bytes };
        if (!id.isValid()) return error.InvalidSpanId;
        return id;
    }

    /// Exactly 16 lowercase hex digits, not all zero.
    pub fn parseHex(hex: []const u8) error{InvalidSpanId}!SpanId {
        var bytes: [8]u8 = undefined;
        if (!decodeLowerHex(&bytes, hex)) return error.InvalidSpanId;
        return fromBytes(bytes);
    }

    /// The id as lowercase hex, as it appears in a traceparent.
    pub fn toHex(id: SpanId) [16]u8 {
        return std.fmt.bytesToHex(id.bytes, .lower);
    }

    /// Whether the id is not all zero.
    pub fn isValid(id: SpanId) bool {
        return !std.mem.allEqual(u8, &id.bytes, 0);
    }

    /// Prints the id as lowercase hex with `{f}`.
    pub fn format(id: SpanId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&id.toHex());
    }
};

/// W3C trace-flags. Unknown bits are kept in `reserved` as received, but
/// `w3c.formatTraceparent` never sends them.
pub const TraceFlags = packed struct(u8) {
    /// The caller may have recorded trace data.
    sampled: bool = false,
    /// At least the right-most 7 bytes of the trace-id are random (W3C Level 2).
    random: bool = false,
    reserved: u6 = 0,

    /// Flags from a trace-flags byte, unknown bits included.
    pub fn fromByte(byte: u8) TraceFlags {
        return @bitCast(byte);
    }

    /// The flags as a byte, unknown bits included; `w3c.formatTraceparent`
    /// sends only `sampled` and `random`.
    pub fn toByte(flags: TraceFlags) u8 {
        return @bitCast(flags);
    }
};

/// A validated W3C tracestate header value, borrowed from the caller.
///
/// Build it with `w3c.parseTracestate`. The bytes must outlive every
/// `TraceContext` and `Context` that holds the state; to keep a trace longer,
/// set its state to `.empty` or parse a copy you own. A struct literal with
/// unvalidated bytes is a usage error.
pub const TraceState = struct {
    /// The validated value without surrounding whitespace; empty when there
    /// are no entries. Send it as the outgoing `tracestate` value unless it
    /// is empty.
    header: []const u8 = "",

    /// No entries.
    pub const empty: TraceState = .{};

    /// Whether there are no entries; an empty state is not sent.
    pub fn isEmpty(state: TraceState) bool {
        return state.header.len == 0;
    }

    /// One `key=value` member.
    pub const Entry = struct {
        key: []const u8,
        /// Leading spaces belong to the value; trailing ones are not kept.
        value: []const u8,
    };

    /// Visits the entries from left to right, skipping empty members and
    /// members without `=`.
    pub const Iterator = struct {
        rest: []const u8,

        /// The next entry, or null after the last one.
        pub fn next(it: *Iterator) ?Entry {
            while (it.rest.len != 0) {
                const comma = std.mem.findScalar(u8, it.rest, ',');
                const member = std.mem.trim(u8, it.rest[0 .. comma orelse it.rest.len], " \t");
                it.rest = if (comma) |i| it.rest[i + 1 ..] else "";
                const eq = std.mem.findScalar(u8, member, '=') orelse continue;
                return .{ .key = member[0..eq], .value = member[eq + 1 ..] };
            }
            return null;
        }
    };

    /// The entries from left to right; build a changed tracestate from them in
    /// a buffer you own.
    pub fn iterator(state: TraceState) Iterator {
        return .{ .rest = state.header };
    }

    /// The value of the left-most entry with `key`; W3C allows a repeated key.
    pub fn get(state: TraceState, key: []const u8) ?[]const u8 {
        var it = state.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// The identity of the current position in a trace.
///
/// `state` borrows the tracestate bytes (see `TraceState`), so a trace with
/// a non-empty state must not outlive them.
pub const TraceContext = struct {
    trace_id: TraceId,
    /// The span that this context belongs to; the parent-id on the wire.
    span_id: SpanId,
    flags: TraceFlags,
    state: TraceState,
    /// Set by `w3c.parseTraceparent`: the identity came from another process.
    is_remote: bool = false,

    /// Whether both ids are valid (not all zero).
    pub fn isValid(trace: TraceContext) bool {
        return trace.trace_id.isValid() and trace.span_id.isValid();
    }

    /// A child span in the same trace: the new `span_id`, local, with the
    /// parent's flags and state.
    pub fn child(parent: TraceContext, span_id: SpanId) TraceContext {
        std.debug.assert(parent.trace_id.isValid() and span_id.isValid());
        return .{
            .trace_id = parent.trace_id,
            .span_id = span_id,
            .flags = parent.flags,
            .state = parent.state,
            .is_remote = false,
        };
    }
};

/// Decodes `hex` into `out`; false unless it is exactly `2 * out.len`
/// lowercase hex digits.
fn decodeLowerHex(out: []u8, hex: []const u8) bool {
    if (hex.len != out.len * 2) return false;
    for (out, 0..) |*byte, i| {
        const high = lowerHexDigit(hex[2 * i]) orelse return false;
        const low = lowerHexDigit(hex[2 * i + 1]) orelse return false;
        byte.* = high << 4 | low;
    }
    return true;
}

fn lowerHexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

const trace_hex = "4bf92f3577b34da6a3ce929d0e0e4736";
const span_hex = "00f067aa0ba902b7";

test "ids round-trip through hex" {
    const trace_id = try TraceId.parseHex(trace_hex);
    try std.testing.expectEqualStrings(trace_hex, &trace_id.toHex());
    const span_id = try SpanId.parseHex(span_hex);
    try std.testing.expectEqualStrings(span_hex, &span_id.toHex());
    try std.testing.expectEqual(@as(u8, 0x4b), trace_id.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xb7), span_id.bytes[7]);
}

test "ids reject zeros, wrong lengths, uppercase and non-hex" {
    try std.testing.expectError(error.InvalidTraceId, TraceId.parseHex("00000000000000000000000000000000"));
    try std.testing.expectError(error.InvalidTraceId, TraceId.parseHex(trace_hex[0..31]));
    try std.testing.expectError(error.InvalidTraceId, TraceId.parseHex(trace_hex ++ "0"));
    try std.testing.expectError(error.InvalidTraceId, TraceId.parseHex("4BF92F3577B34DA6A3CE929D0E0E4736"));
    try std.testing.expectError(error.InvalidTraceId, TraceId.parseHex("4bf92f3577b34da6a3ce929d0e0e473g"));
    try std.testing.expectError(error.InvalidSpanId, SpanId.parseHex("0000000000000000"));
    try std.testing.expectError(error.InvalidSpanId, SpanId.parseHex("00f067aa0ba902b"));
    try std.testing.expectError(error.InvalidSpanId, SpanId.parseHex("00F067AA0BA902B7"));
    try std.testing.expectError(error.InvalidTraceId, TraceId.fromBytes(@splat(0)));
    try std.testing.expectError(error.InvalidSpanId, SpanId.fromBytes(@splat(0)));
}

test "ids print as hex with {f}" {
    var buffer: [64]u8 = undefined;
    const printed = try std.fmt.bufPrint(&buffer, "{f}/{f}", .{ try TraceId.parseHex(trace_hex), try SpanId.parseHex(span_hex) });
    try std.testing.expectEqualStrings(trace_hex ++ "/" ++ span_hex, printed);
}

test "flags round-trip every byte, unknown bits included" {
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        try std.testing.expectEqual(byte, TraceFlags.fromByte(byte).toByte());
    }
    const flags = TraceFlags.fromByte(0x0b);
    try std.testing.expect(flags.sampled);
    try std.testing.expect(flags.random);
    try std.testing.expectEqual(@as(u6, 0b10), flags.reserved);
}

test "sampled and random are the W3C bits 0x01 and 0x02" {
    const sampled = TraceFlags.fromByte(0x01);
    try std.testing.expect(sampled.sampled and !sampled.random);
    const random = TraceFlags.fromByte(0x02);
    try std.testing.expect(random.random and !random.sampled);
    try std.testing.expectEqual(@as(u8, 0x01), (TraceFlags{ .sampled = true }).toByte());
    try std.testing.expectEqual(@as(u8, 0x02), (TraceFlags{ .random = true }).toByte());
}

test "an empty trace state has no header" {
    try std.testing.expect(TraceState.empty.isEmpty());
    const state: TraceState = .{ .header = "rojo=00f067aa0ba902b7" };
    try std.testing.expect(!state.isEmpty());
}

test "the iterator skips empty members and whitespace around them" {
    const state: TraceState = .{ .header = "rojo=1,, \t congo= t61rcWkgMzE\t,foo=2" };
    var it = state.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("rojo", first.key);
    try std.testing.expectEqualStrings("1", first.value);
    const second = it.next().?;
    try std.testing.expectEqualStrings("congo", second.key);
    try std.testing.expectEqualStrings(" t61rcWkgMzE", second.value);
    try std.testing.expectEqualStrings("2", it.next().?.value);
    try std.testing.expectEqual(@as(?TraceState.Entry, null), it.next());
}

test "get returns the left-most value of a key" {
    const state: TraceState = .{ .header = "foo=1,bar=2,foo=3" };
    try std.testing.expectEqualStrings("1", state.get("foo").?);
    try std.testing.expectEqualStrings("2", state.get("bar").?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.get("baz"));

    const prefixed: TraceState = .{ .header = "foobar=1,foo=2" };
    try std.testing.expectEqualStrings("2", prefixed.get("foo").?);
    try std.testing.expectEqual(@as(?[]const u8, null), prefixed.get("fo"));
}

test "the iterator skips members without '=' instead of failing" {
    const state: TraceState = .{ .header = "garbage,foo=1" };
    try std.testing.expectEqualStrings("1", state.get("foo").?);
}

test "child keeps the trace, flags and state and becomes local" {
    const parent: TraceContext = .{
        .trace_id = try .parseHex(trace_hex),
        .span_id = try .parseHex(span_hex),
        .flags = .{ .sampled = true },
        .state = .{ .header = "rojo=1" },
        .is_remote = true,
    };
    const span_id: SpanId = try .parseHex("b7ad6b7169203331");
    const child = parent.child(span_id);
    try std.testing.expectEqual(parent.trace_id, child.trace_id);
    try std.testing.expectEqual(span_id, child.span_id);
    try std.testing.expect(child.flags.sampled);
    try std.testing.expectEqualStrings("rojo=1", child.state.header);
    try std.testing.expect(!child.is_remote);
    try std.testing.expect(parent.is_remote);
}

test "a trace context is valid only when both ids are" {
    const valid: TraceContext = .{
        .trace_id = try .parseHex(trace_hex),
        .span_id = try .parseHex(span_hex),
        .flags = .{},
        .state = .empty,
    };
    try std.testing.expect(valid.isValid());
    var zero_span = valid;
    zero_span.span_id = .{ .bytes = @splat(0) };
    try std.testing.expect(!zero_span.isValid());
    var zero_trace = valid;
    zero_trace.trace_id = .{ .bytes = @splat(0) };
    try std.testing.expect(!zero_trace.isValid());
}
