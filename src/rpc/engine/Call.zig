//! One call that `rpc.RawServer` admitted: its memory, the copy of its
//! head, its body, how it ends, and what its `rpc.Context` reads. Internal
//! to the module.
//!
//! The memory of a call is counted twice: against its own limit
//! (`max_request_memory_bytes`) and against the server's limit for all
//! calls at once (`max_live_request_memory_bytes`). Admission takes the
//! call itself, the copy of its head and a buffer for the declared length
//! of its body before the transport reads the body; the handler's arena
//! takes the rest as it grows. Over either limit an allocation fails.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const rules = @import("../rules.zig");
const failures = @import("../failures.zig");
const waiting = @import("../wait.zig");
const auth = @import("../auth.zig");
const credentials = @import("../credentials.zig");
const RawServer = @import("RawServer.zig");
const Context = @import("Context.zig").Context;
const CallContext = @import("Context.zig").CallContext;
const Incoming = transport.Incoming;
const Reply = transport.Reply;

const Call = @This();

const log = std.log.scoped(.rpc);

server: *RawServer,
route_index: u32,
/// In the server's queue or among its running calls; under the server's
/// mutex.
node: std.DoublyLinkedList.Node = .{},
budget: Budget,
/// The arena of the call, on `budget`: the copy of the head and all the
/// handler allocates.
arena: std.heap.ArenaAllocator,
/// Exactly the declared length, on `budget`.
body: []u8,
received_at: std.Io.Timestamp,
deadline: core.Deadline,
/// Given by `Incoming.start`.
reply: Reply = undefined,
outcome: std.atomic.Value(Outcome) = .init(.pending),
/// The token of the handler's `core.Context`: set with the outcome.
token: core.CancellationToken = .init,
/// Wakes the supervisor: the handler ended, or an outcome was chosen.
wake: std.Io.Event = .unset,
/// The handler's task has ended; set before `wake`.
handler_done: std.atomic.Value(bool) = .init(false),
/// Whether the handler entered: see `enter` and `closeEntry`.
entry: std.atomic.Value(Entry) = .init(.open),
context: CallContext,

/// How a call ends; the first to choose wins.
pub const Outcome = enum(u8) {
    pending,
    /// The handler's own result goes out.
    finished,
    /// The deadline passed: `deadline_exceeded`.
    deadline,
    /// The client gave up (`Incoming.cancel`): nothing goes out.
    canceled,
    /// The server stops: `unavailable` before the handler started,
    /// `cancelled` after.
    shutdown,
    /// No task for the handler: `resource_exhausted`.
    no_task,
};

/// The handler's task enters the handler, or the supervisor closes the
/// entry first; whichever comes first decides, once.
const Entry = enum(u8) { open, entered, closed };

/// A call for `head` with a buffer of `body_len` bytes for its body.
/// `error.OutOfMemory` when it does not fit the memory of one call or of
/// all calls.
pub fn create(
    server: *RawServer,
    io: std.Io,
    route_index: u32,
    head: *const transport.RequestHead,
    body_len: usize,
    deadline: core.Deadline,
) error{OutOfMemory}!*Call {
    const limits = server.limits;
    // Refuse at once what cannot fit, before taking anything.
    if (headBytes(head) +| body_len > limits.max_request_memory_bytes) return error.OutOfMemory;
    var budget: Budget = .{
        .gpa = server.gpa,
        .limit = limits.max_request_memory_bytes,
        .live = &server.live_bytes,
        .live_limit = limits.max_live_request_memory_bytes,
    };
    if (!budget.take(@sizeOf(Call))) return error.OutOfMemory;
    const call = server.gpa.create(Call) catch {
        budget.give(@sizeOf(Call));
        return error.OutOfMemory;
    };
    const method = &server.methods[route_index];
    call.* = .{
        .server = server,
        .route_index = route_index,
        .budget = budget,
        .arena = undefined,
        .body = &.{},
        .received_at = head.received_at,
        .deadline = deadline,
        .context = .{
            .io = io,
            .operation = core.Context.root.withDeadline(deadline),
            .arena = undefined,
            .route = method.route,
            .request_id = head.request_id,
            .metadata = &.{},
            .peer = .none,
            .server_transport = server.server_transport,
            .map_error = method.map_error,
            .metadata_limits = .{ .max_entries = limits.max_metadata_entries, .max_bytes = limits.max_metadata_bytes },
        },
    };
    // The allocators point into the call: set them once it has its address.
    call.arena = .init(call.budget.allocator());
    call.context.arena = call.arena.allocator();
    call.context.operation = call.context.operation.withCancellation(&call.token);
    errdefer call.destroy();
    call.body = try call.budget.allocator().alloc(u8, body_len);
    try call.copyHead(io, head);
    return call;
}

/// Frees the call and gives its memory back to the server's budget. The
/// copies of the credentials are wiped first.
pub fn destroy(call: *Call) void {
    if (call.context.authorization) |value| std.crypto.secureZero(u8, value);
    credentials.wipeParsed(call.context.credentials);
    call.arena.deinit();
    call.budget.allocator().free(call.body);
    var budget = call.budget;
    call.server.gpa.destroy(call);
    budget.give(@sizeOf(Call));
}

/// What the call takes before its handler runs: itself, the copy of its
/// head and the body.
fn headBytes(head: *const transport.RequestHead) usize {
    var total: usize = @sizeOf(Call) +| head.metadata.len *| @sizeOf(model.Metadata.Entry);
    for (head.metadata) |entry| total = total +| entry.key.len +| entry.value.len;
    return switch (head.peer) {
        .name => |name| total +| name.len,
        .none, .ip => total,
    };
}

/// Copies the metadata, the reserved values apart, and the peer into the
/// arena; builds the server's span from `traceparent` and `tracestate`.
fn copyHead(call: *Call, io: std.Io, head: *const transport.RequestHead) error{OutOfMemory}!void {
    const a = call.arena.allocator();
    const entries = try a.alloc(model.Metadata.Entry, head.metadata.len);
    var count: usize = 0;
    var traceparent: ?[]const u8 = null;
    var tracestate: ?[]const u8 = null;
    for (head.metadata) |entry| {
        const value = try a.dupe(u8, entry.value);
        // Admission let each reserved key through at most once.
        if (std.mem.eql(u8, entry.key, "authorization")) {
            call.context.authorization = value;
        } else if (std.mem.eql(u8, entry.key, "traceparent")) {
            traceparent = value;
        } else if (std.mem.eql(u8, entry.key, "tracestate")) {
            tracestate = value;
        } else if (std.mem.eql(u8, entry.key, "zefir-correlation-id")) {
            call.context.correlation_id = value;
        } else {
            entries[count] = .{ .key = try a.dupe(u8, entry.key), .value = value };
            count += 1;
        }
    }
    call.context.metadata = entries[0..count];
    call.context.peer = switch (head.peer) {
        .none => .none,
        .ip => |ip| .{ .ip = ip },
        .name => |name| .{ .name = try a.dupe(u8, name) },
    };
    if (traceOf(io, traceparent, tracestate)) |trace| call.context.operation = call.context.operation.withTrace(trace);
}

/// The server's span: a child of a valid `traceparent` with a new random
/// span id, and the `tracestate` when it is valid. Null without a valid
/// `traceparent`: the engine starts no trace of its own.
fn traceOf(io: std.Io, traceparent: ?[]const u8, tracestate: ?[]const u8) ?core.TraceContext {
    const parent = core.w3c.parseTraceparent(traceparent orelse return null) catch return null;
    var trace = parent.child(newSpanId(io));
    trace.state = if (tracestate) |state| core.w3c.parseTracestate(state) catch .empty else .empty;
    return trace;
}

fn newSpanId(io: std.Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        // All zero is not a span id; draw again.
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}

/// The call as the transport sees it.
pub fn incoming(call: *Call) Incoming {
    return .{ .ptr = call, .vtable = &incoming_vtable };
}

/// Chooses `outcome` unless another was chosen first; returns the one in
/// effect.
pub fn choose(call: *Call, outcome: Outcome) Outcome {
    return call.outcome.cmpxchgStrong(.pending, outcome, .acq_rel, .acquire) orelse outcome;
}

/// Ends the call with `outcome` unless it has one already: cancels its
/// token and wakes its supervisor. Returns the outcome in effect.
/// Lock-free and never waits.
pub fn stop(call: *Call, io: std.Io, outcome: Outcome) Outcome {
    const chosen = call.choose(outcome);
    if (chosen == outcome) {
        call.token.cancel();
        call.wake.set(io);
    }
    return chosen;
}

/// Runs the call from its start to `reply.release`, in a supervisor's
/// task with cancelation blocked. The handler runs in a task of its own,
/// whose `Future` only the supervisor touches. The deadline, the client's
/// cancel and the stop each choose the outcome once; at most one response
/// goes out, and `release` comes last, once the handler has really ended.
/// An outcome that comes before the handler entered keeps it out: the call
/// ends as one that never started.
pub fn supervise(call: *Call, io: std.Io) void {
    if (call.outcomeBeforeStart(io)) |outcome| return call.endUnstarted(io, outcome, null);
    var handler = io.concurrent(runHandler, .{ call, io }) catch
        return call.endUnstarted(io, call.choose(.no_task), null);

    var result: ?(anyerror![]const u8) = null;
    const outcome: Outcome = outcome: {
        waiting.untilSet(&call.wake, io, call.deadline) catch |err| switch (err) {
            error.Timeout => break :outcome call.stop(io, .deadline),
            // The supervisor blocks cancelation.
            error.Canceled => unreachable,
        };
        const chosen = call.outcome.load(.acquire);
        if (chosen != .pending) break :outcome chosen;
        // Nothing else wakes the supervisor: the handler has ended. Its
        // success still has to beat the deadline and the others.
        std.debug.assert(call.handler_done.load(.acquire));
        result = handler.await(io);
        break :outcome call.choose(if (call.deadline.isExpired(now(io))) .deadline else .finished);
    };
    // Any outcome but the handler's own end closes the entry: a handler
    // that has not entered never runs.
    if (outcome != .finished and !call.closeEntry())
        return call.endUnstarted(io, outcome, if (result == null) &handler else null);
    // A failure of the engine goes out before the handler is canceled: the
    // client does not wait while the handler unwinds.
    var failure: ?model.Failure = switch (outcome) {
        .deadline => call.sendFailure(io, failures.deadline_exceeded, false),
        .shutdown => call.sendFailure(io, failures.stopped, false),
        // The client gave up: nothing goes out.
        .canceled => failures.cancelled,
        .finished => null,
        .pending, .no_task => unreachable,
    };

    var disposition: Reply.Disposition = .completed;
    if (result == null) {
        if (call.handler_done.load(.acquire)) {
            result = handler.await(io);
        } else {
            // Waits until the handler has ended.
            result = handler.cancel(io);
            disposition = .canceled;
        }
    }
    if (outcome == .finished) failure = call.sendResult(io, result.?);
    call.record(io, failure);
    call.reply.release(io, disposition);
}

/// Why the call must not start, if it must not: canceled or stopped while
/// it waited in the queue, the grace of a stop is over, or no budget is
/// left.
fn outcomeBeforeStart(call: *Call, io: std.Io) ?Outcome {
    const chosen = call.outcome.load(.acquire);
    if (chosen != .pending) return chosen;
    if (call.server.grace_over.load(.acquire)) return call.choose(.shutdown);
    if (call.deadline.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return call.choose(.deadline);
    return null;
}

/// Ends a call whose handler never started: a refusal, except for a client
/// that gave up, and `release(.not_started)`: running it elsewhere is
/// safe. `handler`: the task that was to run the handler, if it was
/// started; it ends at once, and `release` waits for it.
pub fn endUnstarted(call: *Call, io: std.Io, outcome: Outcome, handler: ?*std.Io.Future(anyerror![]const u8)) void {
    const failure: model.Failure = switch (outcome) {
        .canceled => failures.cancelled,
        .shutdown => failures.stopping,
        .deadline => failures.deadline_exceeded,
        .no_task => failures.no_task,
        .pending, .finished => unreachable,
    };
    const ended = if (outcome == .canceled) failure else call.sendFailure(io, failure, true);
    if (handler) |task| _ = task.await(io) catch "";
    call.record(io, ended);
    call.reply.release(io, .not_started);
}

/// The handler's task.
fn runHandler(call: *Call, io: std.Io) anyerror![]const u8 {
    defer {
        call.handler_done.store(true, .release);
        call.wake.set(io);
    }
    if (!call.enter(io)) return error.NotEntered;
    const method = &call.server.methods[call.route_index];
    try auth.authenticate(call.contextPtr(), call.server.authenticator, method.auth == .required);
    return method.handler.handle(method.handler.ptr, call.contextPtr(), call.body);
}

/// Lets the handler in, unless the call has an outcome already or its
/// deadline has passed: a task that started late leaves the handler alone,
/// and the supervisor ends the call as one that never started.
fn enter(call: *Call, io: std.Io) bool {
    if (call.deadline.isExpired(now(io))) _ = call.stop(io, .deadline);
    if (call.outcome.load(.acquire) != .pending) return false;
    return call.entry.cmpxchgStrong(.open, .entered, .acq_rel, .monotonic) == null;
}

/// Closes the entry to a handler that has not entered; true when it had.
/// The supervisor calls it once it has an outcome other than the handler's
/// own end.
fn closeEntry(call: *Call) bool {
    const seen = call.entry.cmpxchgStrong(.open, .closed, .acq_rel, .acquire) orelse return false;
    return seen == .entered;
}

fn contextPtr(call: *Call) *Context {
    return @ptrCast(&call.context);
}

/// Sends what the handler returned. Returns the failure the call ends
/// with, if any: the handler's, or what the transport made of a success
/// (`Response too large`, `Response lost`).
fn sendResult(call: *Call, io: std.Io, result: anyerror![]const u8) ?model.Failure {
    const context = &call.context;
    const max = call.server.limits.max_response_bytes;
    if (result) |body| {
        if (body.len > max) return call.sendFailure(io, failures.response_too_large, false);
        return switch (call.send(io, &.{ .status = .ok, .metadata = context.response_metadata.items, .body = body })) {
            .delivered => null,
            .replaced => failures.response_too_large,
            .lost => failures.response_lost,
        };
    } else |err| {
        var failure = failures.fromError(err, context.recorded, context.map_error);
        // Violations travel in the body; the engine and transports never
        // carry them in the failure.
        failure.violations = &.{};
        failure.violations_truncated = false;
        const body = if (err == error.RpcFailure and context.recorded != null) context.failure_body else "";
        if (body.len > max) return call.sendFailure(io, failures.response_too_large, false);
        return switch (call.send(io, &.{ .status = .{ .failure = failure }, .metadata = context.response_metadata.items, .body = body })) {
            .delivered, .lost => failure,
            .replaced => failures.response_too_large,
        };
    }
}

/// Sends a failure of the engine, without metadata or body. Returns the
/// failure the call ends with: this one, or `Response too large` when the
/// transport could not carry it.
fn sendFailure(call: *Call, io: std.Io, failure: model.Failure, refused: bool) model.Failure {
    return switch (call.send(io, &.{ .status = .{ .failure = failure }, .refused = refused })) {
        .delivered, .lost => failure,
        .replaced => failures.response_too_large,
    };
}

/// What became of a response.
const Sent = enum {
    /// The transport took it.
    delivered,
    /// The transport could not carry it: a small `resource_exhausted`
    /// failure went in its place.
    replaced,
    /// The link is gone, and the response with it.
    lost,
};

fn send(call: *Call, io: std.Io, response: *const model.Response) Sent {
    call.reply.send(io, response) catch |err| switch (err) {
        error.ResponseTooLarge => {
            call.reply.send(io, &.{
                .status = .{ .failure = failures.response_too_large },
                .refused = response.refused,
            }) catch {};
            return .replaced;
        },
        error.Closed, error.OutOfMemory, error.Unexpected => return .lost,
        error.Canceled => {
            // The supervisor blocks cancelation, so a transport that keeps
            // the contract never returns it.
            const route = call.context.route;
            log.warn("the server transport returned Canceled from Reply.send while cancelation was blocked; the response of {s}.v{d}.{s} is lost", .{ route.service, route.version, route.method });
            return .lost;
        },
    };
    return .delivered;
}

/// Counts the end of the call for its route: the time, and the failure it
/// ended with, if any, a response the transport lost included. Before
/// `release`: the failure may point into the arena.
fn record(call: *Call, io: std.Io, failure: ?model.Failure) void {
    const stats = &call.server.stats[call.route_index];
    stats.addTime(call.received_at.durationTo(now(io)));
    if (failure) |f| stats.countFailure(io, f);
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

const incoming_vtable: Incoming.VTable = .{ .body = bodyFn, .start = startFn, .abandon = abandonFn, .cancel = cancelFn };

fn bodyFn(ptr: *anyopaque) []u8 {
    const call: *Call = @ptrCast(@alignCast(ptr));
    return call.body;
}

fn startFn(ptr: *anyopaque, io: std.Io, reply: Reply) ?model.Failure {
    const call: *Call = @ptrCast(@alignCast(ptr));
    // Starting a task allocates: a cancelation request of the transport's
    // task stays for its next cancelation point.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    call.reply = reply;
    return call.server.schedule(io, call);
}

fn abandonFn(ptr: *anyopaque, io: std.Io) void {
    const call: *Call = @ptrCast(@alignCast(ptr));
    call.server.retire(io, call);
}

fn cancelFn(ptr: *anyopaque, io: std.Io) void {
    const call: *Call = @ptrCast(@alignCast(ptr));
    _ = call.stop(io, .canceled);
}

/// An allocator that counts what one call takes, against the call's limit
/// and the server's limit for all calls.
const Budget = struct {
    gpa: std.mem.Allocator,
    used: std.atomic.Value(usize) = .init(0),
    limit: usize,
    live: *std.atomic.Value(usize),
    live_limit: usize,

    fn take(b: *Budget, n: usize) bool {
        if (!reserve(&b.used, n, b.limit)) return false;
        if (!reserve(b.live, n, b.live_limit)) {
            _ = b.used.fetchSub(n, .monotonic);
            return false;
        }
        return true;
    }

    fn give(b: *Budget, n: usize) void {
        _ = b.used.fetchSub(n, .monotonic);
        _ = b.live.fetchSub(n, .monotonic);
    }

    fn allocator(b: *Budget) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        if (!b.take(len)) return null;
        return b.gpa.rawAlloc(len, alignment, ret_addr) orelse {
            b.give(len);
            return null;
        };
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len) {
            const more = new_len - memory.len;
            if (!b.take(more)) return false;
            if (b.gpa.rawResize(memory, alignment, new_len, ret_addr)) return true;
            b.give(more);
            return false;
        }
        if (!b.gpa.rawResize(memory, alignment, new_len, ret_addr)) return false;
        b.give(memory.len - new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        if (new_len > memory.len) {
            const more = new_len - memory.len;
            if (!b.take(more)) return null;
            return b.gpa.rawRemap(memory, alignment, new_len, ret_addr) orelse {
                b.give(more);
                return null;
            };
        }
        const moved = b.gpa.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        b.give(memory.len - new_len);
        return moved;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        b.gpa.rawFree(memory, alignment, ret_addr);
        b.give(memory.len);
    }
};

/// Adds `n` to `counter` unless the sum would pass `limit`.
fn reserve(counter: *std.atomic.Value(usize), n: usize, limit: usize) bool {
    var current = counter.load(.monotonic);
    while (true) {
        if (n > limit - current) return false;
        current = counter.cmpxchgWeak(current, current + n, .monotonic, .monotonic) orelse return true;
    }
}

const testing = std.testing;

test "a budget counts what it takes against both limits" {
    var live: std.atomic.Value(usize) = .init(0);
    var a: Budget = .{ .gpa = testing.allocator, .limit = 100, .live = &live, .live_limit = 150 };
    var b: Budget = .{ .gpa = testing.allocator, .limit = 100, .live = &live, .live_limit = 150 };

    const first = try a.allocator().alloc(u8, 60);
    try testing.expectError(error.OutOfMemory, a.allocator().alloc(u8, 41));
    const second = try b.allocator().alloc(u8, 90);
    try testing.expectEqual(@as(usize, 150), live.load(.monotonic));
    // Under its own limit, but over the server's.
    try testing.expectError(error.OutOfMemory, a.allocator().alloc(u8, 1));

    // Shrinking gives back; growing takes, or fails over a limit.
    b.allocator().free(second);
    try testing.expectEqual(@as(usize, 60), live.load(.monotonic));
    var grown = first;
    if (a.allocator().resize(grown, 100)) grown.len = 100;
    try testing.expectEqual(a.used.load(.monotonic), live.load(.monotonic));
    try testing.expect(!a.allocator().resize(grown, 101));
    a.allocator().free(grown);
    try testing.expectEqual(@as(usize, 0), live.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), a.used.load(.monotonic));
}

test "an arena on a budget fails over the limit and gives everything back" {
    var live: std.atomic.Value(usize) = .init(0);
    var budget: Budget = .{ .gpa = testing.allocator, .limit = 64 * 1024, .live = &live, .live_limit = 1 << 20 };
    var arena: std.heap.ArenaAllocator = .init(budget.allocator());
    const a = arena.allocator();
    _ = try a.alloc(u8, 1000);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 64 * 1024));
    _ = try a.alloc(u8, 1000);
    try testing.expect(live.load(.monotonic) > 2000);
    arena.deinit();
    try testing.expectEqual(@as(usize, 0), live.load(.monotonic));
}
