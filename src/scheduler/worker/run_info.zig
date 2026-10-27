//! What a run knows of itself: its `RunInfo`, and the context of its
//! operation, which goes on with the trace of the caller of `schedule`.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Allocator = std.mem.Allocator;
const core = @import("core");
const record = @import("../record.zig");
const RunInfo = @import("../Context.zig").RunInfo;

/// The `RunInfo` of a claimed record, with the `attempts` of its policy and
/// the moments `missed` that its run stands for; its strings are in
/// `arena`. `run_key` is "<job>/<key>/<scheduled_at in ms>", the same for
/// every attempt of the run.
pub fn runInfo(arena: Allocator, r: *const record.Record, attempts: u32, missed: u32, instance: []const u8) Allocator.Error!RunInfo {
    return .{
        .job = try arena.dupe(u8, r.job),
        .key = try arena.dupe(u8, r.key),
        .tenant = if (r.tenant) |tenant| try arena.dupe(u8, tenant) else null,
        .run_key = try std.fmt.allocPrint(arena, "{s}/{s}/{d}", .{ r.job, r.key, r.scheduled_at.unix_ms }),
        .attempt = r.attempt,
        .attempts = attempts,
        .scheduled_at = r.scheduled_at,
        // A claimed record has its claimed_at.
        .started_at = r.claimed_at orelse r.scheduled_at,
        .missed = missed,
        .life = r.life,
        .fence = r.fence,
        .instance = try arena.dupe(u8, instance),
    };
}

/// The context of a run: `core.Context.root` with the deadline of the job's
/// `timeout` on the awake clock, `token`, and the record's `trace` (the
/// traceparent of the caller of `schedule`) continued with a new span id
/// from `io.random`. A record without a trace, or with one that does not
/// read, gives the run a trace of its own.
pub fn operation(io: Io, trace: ?[]const u8, timeout: ?Duration, token: *const core.CancellationToken) core.Context {
    var ctx = core.Context.root.withCancellation(token);
    if (timeout) |budget| ctx = ctx.withDeadline(.after(Io.Clock.awake.now(io), budget));
    const parent: ?core.TraceContext = if (trace) |text| core.w3c.parseTraceparent(text) catch null else null;
    return ctx.withTrace(if (parent) |p| p.child(spanId(io)) else newTrace(io));
}

/// A trace of its own: random ids, not sampled.
fn newTrace(io: Io) core.TraceContext {
    const trace_id = while (true) {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        // All zero is no trace id; draw again.
        break core.TraceId.fromBytes(bytes) catch continue;
    };
    return .{ .trace_id = trace_id, .span_id = spanId(io), .flags = .{ .random = true }, .state = .empty };
}

fn spanId(io: Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}
