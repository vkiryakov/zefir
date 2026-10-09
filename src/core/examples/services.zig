//! Context propagation through three services without a network:
//! Gateway → User Service (same process) → Billing Service (over a simulated
//! wire). Run by `zig build test`; it fails if an invariant breaks.
//!
//! In process, the context itself travels: the child shares the token and
//! the deadline. Over the wire only the W3C headers and a millisecond budget
//! travel; the receiver builds its own deadline and owns its own token.

const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var recorder: Recorder = .{};

    // The request scope owns the header bytes and the token; every context
    // below borrows them and ends with the request.
    const traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const tracestate = "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE";
    var token: core.CancellationToken = .init;

    var incoming = try core.w3c.parseTraceparent(traceparent);
    incoming.state = core.w3c.parseTracestate(tracestate) catch .empty;

    const now = std.Io.Clock.awake.now(io);
    const ctx = core.Context.root
        .withTrace(incoming.child(newSpanId(io)))
        .withDeadline(.after(now, .fromMilliseconds(300)))
        .withCancellation(&token);
    recorder.record("gateway", ctx, incoming.span_id, now);

    try userService(ctx, io, &recorder);
    for (recorder.hops[0..recorder.len]) |hop| {
        try out.print("{s:<8} trace {f} span {f} parent {f} budget {f} vendor entries {d}\n", .{
            hop.service, hop.trace_id, hop.span_id, hop.parent_span_id, hop.budget, hop.vendor_entries,
        });
    }
    try checkTrail(recorder, incoming);

    // A job that must outlive the request gets its own context from root.
    var job_token: core.CancellationToken = .init;
    const job = auditJobContext(ctx, io, &job_token);

    // The client went away: cancelling the request reaches User Service
    // through the shared token, but not the detached job.
    token.cancel();
    if (userService(ctx, io, &recorder)) |_| {
        return error.ExpectedCancellation;
    } else |err| switch (err) {
        error.Cancelled => try out.print("after cancel: {t}\n", .{err}),
        else => return err,
    }
    try job.check(std.Io.Clock.awake.now(io));
    if (job.trace.?.trace_id.bytes[0] != incoming.trace_id.bytes[0]) return error.JobLostTrace;
    if (!job.trace.?.state.isEmpty()) return error.JobBorrowsRequestState;
    if (job.deadline.?.expires.nanoseconds <= ctx.deadline.?.expires.nanoseconds) return error.JobInheritedDeadline;
}

fn userService(ctx: core.Context, io: std.Io, recorder: *Recorder) !void {
    const now = std.Io.Clock.awake.now(io);
    try ctx.check(now);
    const child = ctx.withTrace(ctx.trace.?.child(newSpanId(io)));
    recorder.record("user", child, ctx.trace.?.span_id, now);
    try callBilling(child, io, recorder);
}

/// What crosses the wire. The message owns its bytes, as a received network
/// message would.
const Message = struct {
    traceparent: [core.w3c.traceparent_len]u8 = undefined,
    tracestate: [512]u8 = undefined,
    tracestate_len: usize = 0,
    budget_ms: u32 = 0,
};

/// The client side of the call: headers and the remaining budget, never the
/// local clock's timestamps.
fn callBilling(ctx: core.Context, io: std.Io, recorder: *Recorder) !void {
    const now = std.Io.Clock.awake.now(io);
    try ctx.check(now);

    var message: Message = .{};
    _ = core.w3c.formatTraceparent(ctx.trace.?, &message.traceparent);
    const state = ctx.trace.?.state.header;
    // A transport with a size limit drops the whole tracestate, never part of it.
    if (state.len <= message.tracestate.len) {
        @memcpy(message.tracestate[0..state.len], state);
        message.tracestate_len = state.len;
    }
    const remaining_ms = ctx.remaining(now).?.toMilliseconds();
    if (remaining_ms < 1) return error.DeadlineExceeded;
    message.budget_ms = std.math.cast(u32, remaining_ms) orelse std.math.maxInt(u32);

    try billingService(io, &message, recorder);
}

/// The server side: its own call scope, token and deadline.
fn billingService(io: std.Io, message: *const Message, recorder: *Recorder) !void {
    var token: core.CancellationToken = .init;
    const now = std.Io.Clock.awake.now(io);

    var parent = try core.w3c.parseTraceparent(&message.traceparent);
    parent.state = core.w3c.parseTracestate(message.tracestate[0..message.tracestate_len]) catch .empty;

    const ctx = core.Context.root
        .withTrace(parent.child(newSpanId(io)))
        .withDeadline(.after(now, .fromMilliseconds(message.budget_ms)))
        .withCancellation(&token);
    try ctx.check(now);
    recorder.record("billing", ctx, parent.span_id, now);
}

/// A background job that keeps running after the request: it starts from
/// root, owns its token and deadline, and copies only values from the request.
fn auditJobContext(request: core.Context, io: std.Io, job_token: *const core.CancellationToken) core.Context {
    var trace = request.trace.?.child(newSpanId(io));
    trace.state = .empty; // the request's tracestate bytes end with the request
    return core.Context.root
        .withTrace(trace)
        .withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(30)))
        .withCancellation(job_token);
}

fn newSpanId(io: std.Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}

const Hop = struct {
    service: []const u8,
    trace_id: core.TraceId,
    span_id: core.SpanId,
    parent_span_id: core.SpanId,
    budget: std.Io.Duration,
    vendor_entries: usize,
};

/// Stands in for a tracer: every service records what its context says.
const Recorder = struct {
    hops: [3]Hop = undefined,
    len: usize = 0,

    fn record(recorder: *Recorder, service: []const u8, ctx: core.Context, parent_span_id: core.SpanId, now: std.Io.Timestamp) void {
        const trace = ctx.trace.?;
        var entries: usize = 0;
        var it = trace.state.iterator();
        while (it.next()) |_| entries += 1;
        recorder.hops[recorder.len] = .{
            .service = service,
            .trace_id = trace.trace_id,
            .span_id = trace.span_id,
            .parent_span_id = parent_span_id,
            .budget = ctx.remaining(now).?,
            .vendor_entries = entries,
        };
        recorder.len += 1;
    }
};

fn checkTrail(recorder: Recorder, incoming: core.TraceContext) !void {
    const hops = recorder.hops[0..recorder.len];
    if (hops.len != 3) return error.MissingHop;
    var parent = incoming.span_id;
    for (hops, 0..) |hop, i| {
        if (!std.mem.eql(u8, &hop.trace_id.bytes, &incoming.trace_id.bytes)) return error.TraceChanged;
        if (!std.mem.eql(u8, &hop.parent_span_id.bytes, &parent.bytes)) return error.WrongParent;
        if (std.mem.eql(u8, &hop.span_id.bytes, &parent.bytes)) return error.SpanReused;
        if (hop.vendor_entries != 2) return error.VendorStateLost;
        if (i > 0 and hop.budget.nanoseconds > hops[i - 1].budget.nanoseconds) return error.BudgetGrew;
        parent = hop.span_id;
    }
}
