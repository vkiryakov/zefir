//! The trace identity and the W3C headers, with the values they give: the
//! two functions of a transport's adapter, one that reads the headers of an
//! incoming message and one that writes those of an outgoing one, then ids,
//! flags and the tracestate.

const std = @import("std");
const core = @import("core");

const testing = std.testing;

/// The trace of an incoming message; null when its traceparent is bad, and
/// the service starts a new trace.
fn receive(traceparent: []const u8, tracestate: []const u8) ?core.TraceContext {
    const trace: ?core.TraceContext = if (core.w3c.parseTraceparent(traceparent)) |parsed| blk: {
        var with_state = parsed;
        with_state.state = core.w3c.parseTracestate(tracestate) catch .empty; // a bad tracestate is dropped
        break :blk with_state;
    } else |_| null; // a bad traceparent restarts the trace; tracestate is not parsed
    return trace;
}

/// Writes the trace headers of an outgoing message, a `name: value` line
/// each.
fn send(w: *std.Io.Writer, trace: core.TraceContext) std.Io.Writer.Error!void {
    var traceparent: [core.w3c.traceparent_len]u8 = undefined;
    const value = core.w3c.formatTraceparent(trace, &traceparent); // always version 00
    try w.print("{s}: {s}\n", .{ core.w3c.traceparent_header, value });
    if (!trace.state.isEmpty()) try w.print("{s}: {s}\n", .{ core.w3c.tracestate_header, trace.state.header });
}

test "a service passes the trace on: the same trace, its own span, the tracestate as it came" {
    const incoming = receive(
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE",
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(incoming.is_remote);
    try testing.expect(incoming.flags.sampled);
    try testing.expectEqualDeep(@as(?[]const u8, "t61rcWkgMzE"), incoming.state.get("congo"));

    // The span of this service: a child in the same trace, and local.
    const span = incoming.child(try .parseHex("b7ad6b7169203331"));
    try testing.expect(!span.is_remote);
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try send(&w, span);
    try testing.expectEqualStrings(
        \\traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-b7ad6b7169203331-01
        \\tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
        \\
    , w.buffered());
}

test "a bad tracestate is dropped, and the traceparent stays" {
    // A key starts with a lowercase letter or a digit.
    const incoming = receive("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "Rojo=00f067aa0ba902b7") orelse return error.TestUnexpectedResult;
    try testing.expect(incoming.state.isEmpty());

    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try send(&w, incoming.child(try .parseHex("b7ad6b7169203331")));
    try testing.expectEqualStrings("traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-b7ad6b7169203331-01\n", w.buffered());
}

test "a bad traceparent restarts the trace" {
    try testing.expect(receive("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", "rojo=1") == null); // uppercase
    try testing.expect(receive("00-00000000000000000000000000000000-00f067aa0ba902b7-01", "rojo=1") == null); // all zero
    try testing.expect(receive("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-", "rojo=1") == null); // version 00 ends there
}

test "a newer version is read the W3C way, and a trace is written as version 00 with the known flags only" {
    const newer = receive("cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-what-comes-next", "") orelse return error.TestUnexpectedResult;
    // 0x0b: sampled, random and a bit that version 00 does not define; the
    // spaces and tabs around a value do not count.
    const unknown_bits = receive(" 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0b\t", "") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0x0b), unknown_bits.flags.toByte());
    try testing.expect(unknown_bits.flags.sampled and unknown_bits.flags.random);

    var traceparent: [core.w3c.traceparent_len]u8 = undefined;
    try testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", core.w3c.formatTraceparent(newer, &traceparent));
    try testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03", core.w3c.formatTraceparent(unknown_bits, &traceparent));
}

test "ids are lowercase hex, never all zero, and print with {f}" {
    const trace_id: core.TraceId = try .parseHex("4bf92f3577b34da6a3ce929d0e0e4736");
    const span_id: core.SpanId = try .fromBytes(.{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 });
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736 00f067aa0ba902b7", try std.fmt.bufPrint(&buffer, "{f} {f}", .{ trace_id, span_id }));
    try testing.expectEqualStrings("00f067aa0ba902b7", &span_id.toHex());

    try testing.expectError(error.InvalidTraceId, core.TraceId.parseHex("4BF92F3577B34DA6A3CE929D0E0E4736"));
    try testing.expectError(error.InvalidSpanId, core.SpanId.fromBytes(@splat(0)));
}

test "a tracestate keeps a repeated key, and get returns the left-most value" {
    const state = try core.w3c.parseTracestate("rojo=1, ,congo=2 ,rojo=3");
    try testing.expectEqualDeep(@as(?[]const u8, "1"), state.get("rojo"));
    try testing.expectEqualDeep(@as(?[]const u8, null), state.get("vert"));

    var keys: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = state.iterator();
    while (it.next()) |entry| : (count += 1) {
        if (count == keys.len) return error.TestUnexpectedResult;
        keys[count] = entry.key;
    }
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "rojo", "congo", "rojo" }), @as([]const []const u8, keys[0..count]));
}
