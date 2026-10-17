//! The identity of a request (design section 17): its id, and its trace,
//! continued from the client's `traceparent` or new.
const std = @import("std");
const core = @import("core");
const h1 = @import("h1/head.zig");

/// A new request id: 16 random bytes as 32 lowercase hex digits.
pub fn newRequestId(io: std.Io) [32]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// The trace of a request. A valid `traceparent` is continued: the same
/// trace with a new span of the server, and the `tracestate` when it is
/// valid (several fields joined with ','), copied into `arena`. Without
/// one, with a broken one or with two, the trace is new.
pub fn traceOf(io: std.Io, arena: std.mem.Allocator, fields: []const h1.Field) error{OutOfMemory}!core.TraceContext {
    var traceparent: ?[]const u8 = null;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, core.w3c.traceparent_header)) continue;
        // Two traceparent fields are invalid together.
        if (traceparent != null) return newTrace(io);
        traceparent = f.value;
    }
    const parent = core.w3c.parseTraceparent(traceparent orelse return newTrace(io)) catch return newTrace(io);
    var trace = parent.child(newSpanId(io));
    trace.state = try stateOf(arena, fields);
    return trace;
}

/// The `tracestate` fields joined with ',' in arena memory; empty when
/// there are none or the value is not valid.
fn stateOf(arena: std.mem.Allocator, fields: []const h1.Field) error{OutOfMemory}!core.TraceState {
    var len: usize = 0;
    var count: usize = 0;
    for (fields) |f| if (std.ascii.eqlIgnoreCase(f.name, core.w3c.tracestate_header)) {
        len += f.value.len;
        count += 1;
    };
    if (count == 0) return .empty;
    const joined = try arena.alloc(u8, len + count - 1);
    var at: usize = 0;
    for (fields) |f| if (std.ascii.eqlIgnoreCase(f.name, core.w3c.tracestate_header)) {
        if (at > 0) {
            joined[at] = ',';
            at += 1;
        }
        @memcpy(joined[at..][0..f.value.len], f.value);
        at += f.value.len;
    };
    return core.w3c.parseTracestate(joined) catch .empty;
}

/// A trace of its own: random ids.
pub fn newTrace(io: std.Io) core.TraceContext {
    const trace_id = while (true) {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        // All zero is not a trace id; draw again.
        break core.TraceId.fromBytes(bytes) catch continue;
    };
    return .{ .trace_id = trace_id, .span_id = newSpanId(io), .flags = .{ .random = true }, .state = .empty };
}

fn newSpanId(io: std.Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}

const testing = std.testing;

test "traceparent: a valid one continues its trace with a new span; none or a broken one starts a new trace" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

    // Continued: the same trace and flags, a new span, the state joined.
    const continued = try traceOf(io, arena, &.{
        .{ .name = "TraceParent", .value = parent },
        .{ .name = "tracestate", .value = "congo=t61rcWkgMzE" },
        .{ .name = "Tracestate", .value = "rojo=00f067aa0ba902b7" },
    });
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &continued.trace_id.toHex());
    try testing.expect(!std.mem.eql(u8, "00f067aa0ba902b7", &continued.span_id.toHex()));
    try testing.expect(continued.flags.sampled and !continued.is_remote);
    try testing.expectEqualStrings("congo=t61rcWkgMzE,rojo=00f067aa0ba902b7", continued.state.header);
    try testing.expectEqualStrings("00f067aa0ba902b7", continued.state.get("rojo").?);

    // A broken tracestate is dropped; the trace goes on.
    const bad_state = try traceOf(io, arena, &.{ .{ .name = "traceparent", .value = parent }, .{ .name = "tracestate", .value = "=bad" } });
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &bad_state.trace_id.toHex());
    try testing.expect(bad_state.state.isEmpty());

    // New: no traceparent, a broken one, two of them; a tracestate alone is dropped.
    for ([_][]const h1.Field{
        &.{.{ .name = "tracestate", .value = "congo=t61rcWkgMzE" }},
        &.{.{ .name = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7" }},
        &.{.{ .name = "traceparent", .value = "00-00000000000000000000000000000000-00f067aa0ba902b7-01" }},
        &.{ .{ .name = "traceparent", .value = parent }, .{ .name = "traceparent", .value = parent } },
    }) |fields| {
        const fresh = try traceOf(io, arena, fields);
        try testing.expect(fresh.isValid());
        try testing.expect(!std.mem.eql(u8, "4bf92f3577b34da6a3ce929d0e0e4736", &fresh.trace_id.toHex()));
        try testing.expect(fresh.state.isEmpty() and fresh.flags.random and !fresh.flags.sampled);
    }
    // Two new traces differ.
    try testing.expect(!std.mem.eql(u8, &newTrace(io).trace_id.toHex(), &newTrace(io).trace_id.toHex()));
}

test "a request id is 32 lowercase hex digits, new each time" {
    const a = newRequestId(testing.io);
    const b = newRequestId(testing.io);
    for (a) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
