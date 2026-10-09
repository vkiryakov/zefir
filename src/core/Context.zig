//! The execution context of one operation: trace identity, deadline and
//! cancellation. A small value (96 bytes) that code passes down by value.
//!
//! ```zig
//! var token: core.CancellationToken = .init; // owned by the request scope
//! const now = std.Io.Clock.awake.now(io);
//! const ctx = core.Context.root
//!     .withDeadline(.after(now, .fromMilliseconds(500)))
//!     .withCancellation(&token);
//! try ctx.check(std.Io.Clock.awake.now(io)); // error.Cancelled or error.DeadlineExceeded
//! ```
//!
//! Every `with*` returns a new context and leaves the original unchanged.
//! The fields are read-only: derive contexts with `with*`, which never
//! extends a deadline. A context owns nothing and does no I/O; it borrows
//! the token and the tracestate bytes, so it must not outlive them.

const std = @import("std");
const CancellationToken = @import("CancellationToken.zig");
const Deadline = @import("Deadline.zig");
const ContextError = @import("errors.zig").ContextError;
const TraceContext = @import("trace.zig").TraceContext;
const TraceId = @import("trace.zig").TraceId;
const SpanId = @import("trace.zig").SpanId;

const Context = @This();

/// Trace identity, or null when tracing is off. Read-only.
trace: ?TraceContext = null,
/// The earliest deadline in effect, or null. Read-only.
deadline: ?Deadline = null,
/// The token that cancels this operation, or null. Read-only.
cancellation: ?*const CancellationToken = null,

/// No trace, no deadline, no token.
pub const root: Context = .{};

/// Replaces the trace identity. The ids must be valid.
pub fn withTrace(ctx: Context, trace: TraceContext) Context {
    std.debug.assert(trace.isValid());
    var derived = ctx;
    derived.trace = trace;
    return derived;
}

/// Adds a deadline; the earlier of the new and the current one stays.
pub fn withDeadline(ctx: Context, deadline: Deadline) Context {
    var derived = ctx;
    derived.deadline = if (ctx.deadline) |current| current.earliest(deadline) else deadline;
    return derived;
}

/// Replaces the token. The derived context no longer sees the old token,
/// but keeps the deadline and the trace: to detach a background job from a
/// request, start from `root` instead.
pub fn withCancellation(ctx: Context, token: *const CancellationToken) Context {
    var derived = ctx;
    derived.cancellation = token;
    return derived;
}

pub fn isCancelled(ctx: Context) bool {
    const token = ctx.cancellation orelse return false;
    return token.isCancelled();
}

pub fn isExpired(ctx: Context, now: std.Io.Timestamp) bool {
    const deadline = ctx.deadline orelse return false;
    return deadline.isExpired(now);
}

/// Time left until the deadline, or null without one. Never negative.
pub fn remaining(ctx: Context, now: std.Io.Timestamp) ?std.Io.Duration {
    const deadline = ctx.deadline orelse return null;
    return deadline.remaining(now);
}

/// `error.Cancelled` if the token is cancelled, else `error.DeadlineExceeded`
/// if the deadline has expired at `now`. Cancellation wins when both hold.
pub fn check(ctx: Context, now: std.Io.Timestamp) ContextError!void {
    if (ctx.isCancelled()) return error.Cancelled;
    if (ctx.isExpired(now)) return error.DeadlineExceeded;
}

fn ts(nanoseconds: i96) std.Io.Timestamp {
    return .fromNanoseconds(nanoseconds);
}

fn testTrace(span_hex: []const u8) !TraceContext {
    return .{
        .trace_id = try TraceId.parseHex("4bf92f3577b34da6a3ce929d0e0e4736"),
        .span_id = try SpanId.parseHex(span_hex),
        .flags = .{ .sampled = true },
        .state = .empty,
    };
}

test "root has no trace, deadline or token" {
    const ctx: Context = .root;
    try std.testing.expectEqual(@as(?TraceContext, null), ctx.trace);
    try std.testing.expectEqual(@as(?Deadline, null), ctx.deadline);
    try std.testing.expectEqual(@as(?*const CancellationToken, null), ctx.cancellation);
    try std.testing.expect(!ctx.isCancelled());
    try std.testing.expect(!ctx.isExpired(ts(std.math.maxInt(i96))));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), ctx.remaining(ts(0)));
    try ctx.check(ts(0));
}

test "derivation leaves the parent unchanged" {
    var token: CancellationToken = .init;
    const parent: Context = Context.root.withTrace(try testTrace("00f067aa0ba902b7"));
    const child = parent
        .withTrace(try testTrace("b7ad6b7169203331"))
        .withDeadline(.at(ts(1_000)))
        .withCancellation(&token);

    try std.testing.expectEqualSlices(u8, &(try SpanId.parseHex("00f067aa0ba902b7")).bytes, &parent.trace.?.span_id.bytes);
    try std.testing.expectEqual(@as(?Deadline, null), parent.deadline);
    try std.testing.expectEqual(@as(?*const CancellationToken, null), parent.cancellation);

    try std.testing.expectEqualSlices(u8, &(try SpanId.parseHex("b7ad6b7169203331")).bytes, &child.trace.?.span_id.bytes);
    try std.testing.expectEqual(@as(i96, 1_000), child.deadline.?.expires.nanoseconds);
    try std.testing.expectEqual(@as(?*const CancellationToken, &token), child.cancellation);
}

test "a child keeps the parent's token and deadline" {
    var token: CancellationToken = .init;
    const parent = Context.root.withDeadline(.at(ts(1_000))).withCancellation(&token);
    const child = parent.withTrace(try testTrace("b7ad6b7169203331"));
    try std.testing.expectEqual(parent.deadline, child.deadline);
    try std.testing.expectEqual(parent.cancellation, child.cancellation);

    token.cancel();
    try std.testing.expect(parent.isCancelled());
    try std.testing.expect(child.isCancelled());
}

test "withDeadline never extends the deadline" {
    const ctx = Context.root.withDeadline(.at(ts(1_000)));
    try std.testing.expectEqual(@as(i96, 1_000), ctx.withDeadline(.at(ts(5_000))).deadline.?.expires.nanoseconds);
    try std.testing.expectEqual(@as(i96, 500), ctx.withDeadline(.at(ts(500))).deadline.?.expires.nanoseconds);
}

test "withCancellation replaces the token" {
    var request_token: CancellationToken = .init;
    var job_token: CancellationToken = .init;
    const request = Context.root.withCancellation(&request_token);
    const job = request.withCancellation(&job_token);
    request_token.cancel();
    try std.testing.expect(request.isCancelled());
    try std.testing.expect(!job.isCancelled());
}

test "check reports cancellation before the deadline" {
    var token: CancellationToken = .init;
    const ctx = Context.root.withDeadline(.at(ts(1_000))).withCancellation(&token);

    try ctx.check(ts(999));
    try std.testing.expectError(error.DeadlineExceeded, ctx.check(ts(1_000)));
    token.cancel();
    try std.testing.expectError(error.Cancelled, ctx.check(ts(999)));
    try std.testing.expectError(error.Cancelled, ctx.check(ts(1_000)));
}

test "remaining comes from the deadline" {
    const ctx = Context.root.withDeadline(.at(ts(1_000)));
    try std.testing.expectEqual(@as(i96, 300), ctx.remaining(ts(700)).?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), ctx.remaining(ts(2_000)).?.nanoseconds);
}

test "a context is a small value" {
    try std.testing.expect(@sizeOf(Context) <= 96);
}

test "threads reading one context see a cancel" {
    const Reader = struct {
        fn run(ctx: Context, seen: *std.atomic.Value(u32)) void {
            while (true) {
                ctx.check(ts(0)) catch |err| switch (err) {
                    error.Cancelled => break,
                    error.DeadlineExceeded => unreachable,
                };
                std.atomic.spinLoopHint();
            }
            _ = seen.fetchAdd(1, .monotonic);
        }
    };
    var token: CancellationToken = .init;
    const ctx = Context.root.withDeadline(.at(ts(1_000))).withCancellation(&token);
    var seen: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Reader.run, .{ ctx, &seen });
    token.cancel();
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, threads.len), seen.load(.monotonic));
}
