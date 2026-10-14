//! A fake engine for tests of server transports. It implements
//! `rpc.transport.Dispatcher` and `rpc.transport.Incoming` as the engine
//! does, records what the transport calls, checks on the way that the
//! transport keeps the rules of `rpc.ServerTransport`, and lets the test
//! answer the calls in place of handlers:
//!
//! ```zig
//! var recorder: rpc.testing.RecordingDispatcher = try .init(gpa, .{ .routes = &routes });
//! defer recorder.deinit(io);
//! try recorder.start(io, my_transport.serverTransport());
//! // A client task sends a call through the transport...
//! try recorder.waitStarted(io, 1);
//! const call = recorder.call(io, 0);
//! try recorder.respond(io, 0, &.{ .status = .ok, .body = call.body.? });
//! recorder.releaseCall(io, 0, .completed);
//! recorder.close(io);
//! try std.testing.expectEqual(0, recorder.violations().len);
//! ```
//!
//! Calls are numbered from 0 in the order of `admit`, refused ones
//! included. Like the engine, the recorder refuses a route it does not
//! serve (`unimplemented`) and a body over `max_request_bytes`
//! (`resource_exhausted`). It does not check metadata, so a test sees
//! exactly what the transport delivered.
//!
//! A broken rule does not stop the test: it goes to `violations`, which the
//! test checks at the end. The rules of the transport:
//!
//! - every accepted call is started or abandoned, once, by the time `close`
//!   returns;
//! - before `start` the transport asks for a body that is not empty
//!   (`Incoming.body`), and after `start` it does not write to it;
//! - `cancel` comes only from the moment `start` is entered until
//!   `Reply.release` returns: never for a call that did not start, never
//!   after `start` returned a failure;
//! - once `close` has returned, the transport calls neither the dispatcher
//!   nor a call.
//!
//! The recorder keeps the engine's rules too: one response a call (one more
//! only after `ResponseTooLarge`) and one release. When the test asks for
//! more, the recorder records a violation instead of calling the transport.
//!
//! The recorder stays at one address from `dispatcher` or `start` until
//! `deinit`: the transport keeps a pointer to it.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const ServerTransport = @import("../ServerTransport.zig");
const Dispatcher = transport.Dispatcher;
const Incoming = transport.Incoming;
const Reply = transport.Reply;

const RecordingDispatcher = @This();

gpa: std.mem.Allocator,
service_value: Dispatcher.Service,
route_counters: []RouteCounter,
mutex: std.Io.Mutex = .init,
/// Broadcast when a call starts.
started_changed: std.Io.Condition = .init,
admit_mode: AdmitMode,
start_mode: StartMode,
server: ?ServerTransport = null,
closed: bool = false,
calls: std.ArrayList(*Call) = .empty,
started: usize = 0,
event_log: std.ArrayList(Event) = .empty,
violation_buffer: [max_violations]Violation = undefined,
violation_len: usize = 0,
fatal_value: ?Fatal = null,

/// The most violations kept; a test fails at the first one anyway.
pub const max_violations = 64;

/// How long `waitStarted` waits before `error.Timeout`.
pub const wait_limit: std.Io.Duration = .fromSeconds(10);

pub const Options = struct {
    /// The routes the fake server serves, in the order of
    /// `Dispatcher.Service.routes`.
    routes: []const model.Route,
    /// The limits of `Dispatcher.Service`, with the engine's defaults.
    max_inflight: u32 = 4352,
    max_request_bytes: usize = 1024 * 1024,
    max_metadata_entries: u32 = 64,
    max_metadata_bytes: u32 = 16 * 1024,
    admit: AdmitMode = .accept,
    start: StartMode = .run,
};

/// How `admit` answers.
pub const AdmitMode = union(enum) {
    /// Admits a call to a served route with a body within
    /// `max_request_bytes`.
    accept,
    /// Refuses every call with this failure; its strings live as long as
    /// the recorder.
    reject: model.Failure,
};

/// How `Incoming.start` answers.
pub const StartMode = union(enum) {
    /// The call runs until the test answers it with `respond` and ends it
    /// with `releaseCall`.
    run,
    /// The engine cannot schedule the call: `start` returns this failure,
    /// and no `Reply` call follows. Its strings live as long as the
    /// recorder.
    fail: model.Failure,
};

/// Where a call is.
pub const State = enum {
    /// `admit` refused it.
    refused,
    /// Admitted, neither started nor abandoned.
    accepted,
    /// Started; the test has not released it.
    running,
    /// `start` returned the failure of `StartMode.fail`.
    start_failed,
    abandoned,
    /// Started and released by the test.
    released,
};

/// A call as the recorder saw it. The slices live until `deinit`.
pub const CallView = struct {
    /// The head that `admit` got, copied.
    head: transport.RequestHead,
    body_len: usize,
    /// The failure of `admit`; null when it admitted the call.
    refusal: ?model.Failure,
    /// The body when `start` came; null before.
    body: ?[]const u8,
    state: State,
    /// How many times the transport canceled the call.
    cancels: u32,
    disposition: ?Reply.Disposition,
};

/// One thing the transport or the test did.
pub const Event = struct {
    /// The index of the call; null for `fail`.
    call: ?u32,
    kind: Kind,

    pub const Kind = union(enum) {
        admit: enum { accepted, refused },
        start: enum { running, failed },
        abandon,
        cancel,
        /// The result of `Reply.send`.
        send: ?Reply.SendError,
        release: Reply.Disposition,
        fail: Dispatcher.FatalError,
    };
};

/// A broken rule.
pub const Violation = struct {
    /// The index of the call; null when the rule is not about one call.
    call: ?u32,
    rule: Rule,
};

pub const Rule = enum {
    /// `close` returned with an accepted call neither started nor
    /// abandoned.
    unresolved_at_close,
    /// A second `start` or `abandon` of one call.
    start_or_abandon_twice,
    /// `start` of a call whose body the transport never asked for.
    body_not_filled,
    /// The transport wrote to the body after `start`.
    body_changed_after_start,
    /// `cancel` of a call that did not start: before `start`, or after
    /// `abandon`.
    cancel_without_start,
    /// `cancel` after `Reply.release` returned, or after `start` returned a
    /// failure.
    cancel_after_end,
    /// The transport called the dispatcher or a call after `close`
    /// returned.
    call_after_close,
    /// The test answered or released a call that is not running: refused,
    /// abandoned or failed to start. Not done.
    reply_without_start,
    /// The test sent a second response. Not sent.
    second_send,
    /// The test answered or released a call it had released. Not done.
    reply_after_release,
};

/// The first `Dispatcher.fail` of the transport.
pub const Fatal = struct {
    err: Dispatcher.FatalError,
    diagnostics: ?transport.Diagnostics,
};

const RouteCounter = struct {
    requests: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
};

/// The recorder's side of one call: the `Incoming` the transport holds.
const Call = struct {
    recorder: *RecordingDispatcher,
    index: u32,
    /// The copies of the head and the two body buffers.
    arena: std.heap.ArenaAllocator,
    head: transport.RequestHead = undefined,
    body_len: usize,
    refusal: ?model.Failure = null,
    /// The body as the transport fills it.
    buffer: []u8 = &.{},
    /// The body when `start` came.
    snapshot: []u8 = &.{},
    has_snapshot: bool = false,
    body_taken: std.atomic.Value(bool) = .init(false),
    body_checked: bool = false,
    state: State = .accepted,
    /// Between `releaseCall` and the return of `Reply.release`.
    releasing: bool = false,
    reply: Reply = undefined,
    sends: u8 = 0,
    retry_allowed: bool = false,
    cancels: u32 = 0,
    disposition: ?Reply.Disposition = null,
};

const incoming_vtable: Incoming.VTable = .{
    .body = bodyFn,
    .start = startFn,
    .abandon = abandonFn,
    .cancel = cancelFn,
};

const dispatcher_vtable: Dispatcher.VTable = .{
    .service = serviceFn,
    .admit = admitFn,
    .fail = failFn,
    .routeStats = routeStatsFn,
};

const unknown_route: model.Failure = .{ .code = .unimplemented, .app_code = "rpc.unknown_method", .message = "Unknown method" };
const too_large: model.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Request too large" };
const out_of_memory: model.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Out of memory" };
const after_close: model.Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server closed" };
const started_twice: model.Failure = .{ .code = .internal, .app_code = "rpc.internal", .message = "Call started twice" };

pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!RecordingDispatcher {
    const route_counters = try gpa.alloc(RouteCounter, options.routes.len);
    @memset(route_counters, .{});
    return .{
        .gpa = gpa,
        .service_value = .{
            .routes = options.routes,
            .max_inflight = options.max_inflight,
            .max_request_bytes = options.max_request_bytes,
            .max_metadata_entries = options.max_metadata_entries,
            .max_metadata_bytes = options.max_metadata_bytes,
        },
        .route_counters = route_counters,
        .admit_mode = options.admit,
        .start_mode = options.start,
    };
}

/// Closes the transport if `close` has not, ends the calls the test left
/// running with `Reply.release(.canceled)`, as the engine's shutdown does,
/// and frees everything. The transport's own `deinit` comes after.
pub fn deinit(r: *RecordingDispatcher, io: std.Io) void {
    r.close(io);
    for (r.calls.items) |c| {
        if (c.state == .running and !c.releasing) {
            c.reply.release(io, .canceled);
            c.state = .released;
        }
    }
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    for (r.calls.items) |c| {
        c.arena.deinit();
        r.gpa.destroy(c);
    }
    r.calls.deinit(r.gpa);
    r.event_log.deinit(r.gpa);
    r.gpa.free(r.route_counters);
    r.* = undefined;
}

/// The dispatcher for `rpc.ServerTransport.start`, when the test drives the
/// transport itself.
pub fn dispatcher(r: *RecordingDispatcher) Dispatcher {
    return .{ .ptr = r, .vtable = &dispatcher_vtable };
}

/// Starts `server` with this recorder as its dispatcher, as
/// `rpc.RawServer.start` does. `drain`, `close` and `deinit` then drive it.
pub fn start(r: *RecordingDispatcher, io: std.Io, server: ServerTransport) ServerTransport.StartError!void {
    r.server = server;
    return server.start(io, r.dispatcher());
}

/// Drains the transport given to `start`.
pub fn drain(r: *RecordingDispatcher, io: std.Io) void {
    if (r.server) |server| server.drain(io);
}

/// Closes the transport given to `start`, then checks that every accepted
/// call was started or abandoned. From here on, a call of the transport
/// into the recorder is a violation. A second call only closes the
/// transport again.
pub fn close(r: *RecordingDispatcher, io: std.Io) void {
    if (r.server) |server| server.close(io);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) return;
    r.closed = true;
    for (r.calls.items) |c| {
        if (c.state == .accepted) r.addViolation(c.index, .unresolved_at_close);
        r.checkBody(c);
    }
}

/// Changes how `admit` answers the next calls.
pub fn setAdmit(r: *RecordingDispatcher, io: std.Io, mode: AdmitMode) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.admit_mode = mode;
}

/// Changes how `start` answers the next calls.
pub fn setStart(r: *RecordingDispatcher, io: std.Io, mode: StartMode) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.start_mode = mode;
}

/// Waits until `n` calls have started, for at most `wait_limit`.
pub fn waitStarted(r: *RecordingDispatcher, io: std.Io, n: usize) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), wait_limit);
    try r.mutex.lock(io);
    defer r.mutex.unlock(io);
    while (r.started < n) {
        r.started_changed.waitTimeout(io, &r.mutex, deadline.toTimeout()) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // A wait with a timeout also wakes spuriously.
            error.Timeout => if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.Timeout,
        };
    }
}

/// Call `index` as the recorder saw it so far.
pub fn call(r: *RecordingDispatcher, io: std.Io, index: usize) CallView {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const c = r.callAt(index);
    return .{
        .head = c.head,
        .body_len = c.body_len,
        .refusal = c.refusal,
        .body = if (c.has_snapshot) c.snapshot else null,
        .state = c.state,
        .cancels = c.cancels,
        .disposition = c.disposition,
    };
}

/// Sends `response` for the running call `index` through its `Reply`,
/// as a handler's answer, and returns what the transport returned. A call
/// that is not running, or a second response, is a violation and is not
/// sent; one more response is allowed after `ResponseTooLarge`.
pub fn respond(r: *RecordingDispatcher, io: std.Io, index: usize, response: *const model.Response) Reply.SendError!void {
    const c = c: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const c = r.callAt(index);
        if (misuse(c)) |rule| {
            r.addViolation(c.index, rule);
            return;
        }
        if (c.sends > 0 and !c.retry_allowed) {
            r.addViolation(c.index, .second_send);
            return;
        }
        c.retry_allowed = false;
        c.sends += 1;
        break :c c;
    };
    const result = c.reply.send(io, response);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const failed: ?Reply.SendError = if (result) |_| null else |err| err;
    c.retry_allowed = c.sends == 1 and if (failed) |err| err == error.ResponseTooLarge else false;
    r.logEvent(c.index, .{ .send = failed });
    return result;
}

/// Ends the running call `index` with `Reply.release`, as the engine does
/// once the handler is over. A call that is not running is a violation and
/// is not released.
pub fn releaseCall(r: *RecordingDispatcher, io: std.Io, index: usize, disposition: Reply.Disposition) void {
    const c = c: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const c = r.callAt(index);
        if (misuse(c)) |rule| {
            r.addViolation(c.index, rule);
            return;
        }
        c.releasing = true;
        break :c c;
    };
    c.reply.release(io, disposition);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    c.releasing = false;
    c.state = .released;
    c.disposition = disposition;
    r.checkBody(c);
    r.logEvent(c.index, .{ .release = disposition });
}

/// What the transport and the test did, in order. Read it when nothing
/// else calls the recorder, such as after `close`. Under memory pressure
/// events may be missing; the checks of the rules do not depend on them.
pub fn events(r: *const RecordingDispatcher) []const Event {
    return r.event_log.items;
}

/// The broken rules, at most `max_violations`. Read them when nothing else
/// calls the recorder, such as after `close`.
pub fn violations(r: *const RecordingDispatcher) []const Violation {
    return r.violation_buffer[0..r.violation_len];
}

/// The first `Dispatcher.fail` of the transport, if any.
pub fn fatal(r: *RecordingDispatcher, io: std.Io) ?Fatal {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    return r.fatal_value;
}

fn callAt(r: *RecordingDispatcher, index: usize) *Call {
    if (index >= r.calls.items.len) @panic("rpc.testing.RecordingDispatcher: no call with this index; calls are numbered in the order of admit");
    return r.calls.items[index];
}

/// Why the test may not answer or release `c` now.
fn misuse(c: *const Call) ?Rule {
    return switch (c.state) {
        .running => if (c.releasing) .reply_after_release else null,
        .released => .reply_after_release,
        .refused, .accepted, .start_failed, .abandoned => .reply_without_start,
    };
}

fn addViolation(r: *RecordingDispatcher, index: ?u32, rule: Rule) void {
    if (r.violation_len == max_violations) return;
    r.violation_buffer[r.violation_len] = .{ .call = index, .rule = rule };
    r.violation_len += 1;
}

fn logEvent(r: *RecordingDispatcher, index: ?u32, kind: Event.Kind) void {
    r.event_log.append(r.gpa, .{ .call = index, .kind = kind }) catch {};
}

/// The body of a started call must be as it was at `start`.
fn checkBody(r: *RecordingDispatcher, c: *Call) void {
    if (!c.has_snapshot or c.body_checked) return;
    if (!std.mem.eql(u8, c.snapshot, c.buffer)) {
        c.body_checked = true;
        r.addViolation(c.index, .body_changed_after_start);
    }
}

fn findRoute(r: *const RecordingDispatcher, route: model.Route) ?usize {
    for (r.service_value.routes, 0..) |known, i| {
        if (known.version == route.version and std.mem.eql(u8, known.service, route.service) and
            std.mem.eql(u8, known.method, route.method)) return i;
    }
    return null;
}

fn serviceFn(ptr: *anyopaque) *const Dispatcher.Service {
    const r: *RecordingDispatcher = @ptrCast(@alignCast(ptr));
    return &r.service_value;
}

fn routeStatsFn(ptr: *anyopaque, route_index: usize) Dispatcher.RouteStats {
    const r: *RecordingDispatcher = @ptrCast(@alignCast(ptr));
    const counter = &r.route_counters[route_index];
    return .{
        .requests = counter.requests.load(.monotonic),
        .errors = counter.errors.load(.monotonic),
        .processing_time = .zero,
    };
}

fn admitFn(ptr: *anyopaque, io: std.Io, head: *const transport.RequestHead, body_len: usize) Dispatcher.Admission {
    const r: *RecordingDispatcher = @ptrCast(@alignCast(ptr));
    // A Debug allocator that captures a stack trace takes a cancelable
    // lock: blocked, it cannot swallow a cancelation of the transport's task.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);

    const index: u32 = @intCast(r.calls.items.len);
    if (r.closed) r.addViolation(index, .call_after_close);
    const route_index = r.findRoute(head.route);
    const refusal: ?model.Failure = if (r.closed)
        after_close
    else if (route_index == null)
        unknown_route
    else if (body_len > r.service_value.max_request_bytes)
        too_large
    else switch (r.admit_mode) {
        .accept => null,
        .reject => |failure| failure,
    };
    const c = r.newCall(index, head, if (refusal == null) body_len else 0) catch return .{ .rejected = out_of_memory };
    c.body_len = body_len;
    r.calls.append(r.gpa, c) catch {
        c.arena.deinit();
        r.gpa.destroy(c);
        return .{ .rejected = out_of_memory };
    };
    if (route_index) |i| {
        _ = r.route_counters[i].requests.fetchAdd(1, .monotonic);
        if (refusal != null) _ = r.route_counters[i].errors.fetchAdd(1, .monotonic);
    }
    if (refusal) |failure| {
        c.state = .refused;
        c.refusal = failure;
        r.logEvent(index, .{ .admit = .refused });
        return .{ .rejected = failure };
    }
    r.logEvent(index, .{ .admit = .accepted });
    return .{ .accepted = .{ .ptr = c, .vtable = &incoming_vtable } };
}

fn newCall(r: *RecordingDispatcher, index: u32, head: *const transport.RequestHead, buffer_len: usize) error{OutOfMemory}!*Call {
    const c = try r.gpa.create(Call);
    errdefer r.gpa.destroy(c);
    c.* = .{ .recorder = r, .index = index, .arena = .init(r.gpa), .body_len = 0 };
    errdefer c.arena.deinit();
    const a = c.arena.allocator();
    c.head = try copyHead(a, head);
    c.buffer = try a.alloc(u8, buffer_len);
    @memset(c.buffer, 0);
    c.snapshot = try a.alloc(u8, buffer_len);
    return c;
}

fn copyHead(a: std.mem.Allocator, head: *const transport.RequestHead) error{OutOfMemory}!transport.RequestHead {
    const metadata = try a.alloc(model.Metadata.Entry, head.metadata.len);
    for (metadata, head.metadata) |*copy, entry| {
        copy.* = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
    }
    return .{
        .route = .{
            .service = try a.dupe(u8, head.route.service),
            .version = head.route.version,
            .method = try a.dupe(u8, head.route.method),
        },
        .request_id = head.request_id,
        .codec = try a.dupe(u8, head.codec),
        .timeout = head.timeout,
        .received_at = head.received_at,
        .metadata = metadata,
        .peer = switch (head.peer) {
            .none => .none,
            .ip => |ip| .{ .ip = ip },
            .name => |name| .{ .name = try a.dupe(u8, name) },
        },
    };
}

fn failFn(ptr: *anyopaque, io: std.Io, err: Dispatcher.FatalError, diagnostics: ?*const transport.Diagnostics) void {
    const r: *RecordingDispatcher = @ptrCast(@alignCast(ptr));
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) r.addViolation(null, .call_after_close);
    if (r.fatal_value == null) r.fatal_value = .{ .err = err, .diagnostics = if (diagnostics) |d| d.* else null };
    r.logEvent(null, .{ .fail = err });
}

fn bodyFn(ptr: *anyopaque) []u8 {
    const c: *Call = @ptrCast(@alignCast(ptr));
    c.body_taken.store(true, .release);
    return c.buffer;
}

fn startFn(ptr: *anyopaque, io: std.Io, reply: Reply) ?model.Failure {
    const c: *Call = @ptrCast(@alignCast(ptr));
    const r = c.recorder;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) r.addViolation(c.index, .call_after_close);
    if (c.state != .accepted) {
        r.addViolation(c.index, .start_or_abandon_twice);
        return started_twice;
    }
    if (c.body_len > 0 and !c.body_taken.load(.acquire)) r.addViolation(c.index, .body_not_filled);
    @memcpy(c.snapshot, c.buffer);
    c.has_snapshot = true;
    switch (r.start_mode) {
        .run => {
            c.state = .running;
            c.reply = reply;
            r.started += 1;
            r.started_changed.broadcast(io);
            r.logEvent(c.index, .{ .start = .running });
            return null;
        },
        .fail => |failure| {
            c.state = .start_failed;
            r.logEvent(c.index, .{ .start = .failed });
            return failure;
        },
    }
}

fn abandonFn(ptr: *anyopaque, io: std.Io) void {
    const c: *Call = @ptrCast(@alignCast(ptr));
    const r = c.recorder;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) r.addViolation(c.index, .call_after_close);
    if (c.state == .accepted) c.state = .abandoned else r.addViolation(c.index, .start_or_abandon_twice);
    r.logEvent(c.index, .abandon);
}

fn cancelFn(ptr: *anyopaque, io: std.Io) void {
    const c: *Call = @ptrCast(@alignCast(ptr));
    const r = c.recorder;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) r.addViolation(c.index, .call_after_close);
    switch (c.state) {
        .running => c.cancels += 1,
        .refused, .accepted, .abandoned => r.addViolation(c.index, .cancel_without_start),
        .start_failed, .released => r.addViolation(c.index, .cancel_after_end),
    }
    r.logEvent(c.index, .cancel);
}

const testing = std.testing;

const get_user: model.Route = .{ .service = "users", .version = 1, .method = "getUser" };
const list_users: model.Route = .{ .service = "users", .version = 1, .method = "listUsers" };

fn headOf(route: model.Route) transport.RequestHead {
    return .{
        .route = route,
        .request_id = @splat(9),
        .codec = "json",
        .timeout = .fromMilliseconds(500),
        .received_at = .zero,
        .metadata = &.{},
    };
}

fn accepted(admission: Dispatcher.Admission) !Incoming {
    return switch (admission) {
        .accepted => |incoming| incoming,
        .rejected => error.TestUnexpectedResult,
    };
}

fn refused(admission: Dispatcher.Admission) !model.Failure {
    return switch (admission) {
        .accepted => error.TestUnexpectedResult,
        .rejected => |failure| failure,
    };
}

/// A transport's reply in the tests: counts what the recorder did.
const FakeReply = struct {
    sends: u32 = 0,
    body: [8]u8 = undefined,
    len: usize = 0,
    /// What `send` returns, the first time only.
    first_send: ?Reply.SendError = null,
    released: ?Reply.Disposition = null,

    pub fn send(self: *FakeReply, io: std.Io, response: *const model.Response) Reply.SendError!void {
        _ = io;
        self.sends += 1;
        if (self.sends == 1) if (self.first_send) |err| return err;
        @memcpy(self.body[0..response.body.len], response.body);
        self.len = response.body.len;
    }

    pub fn release(self: *FakeReply, io: std.Io, disposition: Reply.Disposition) void {
        _ = io;
        self.released = disposition;
    }
};

/// Admits and starts one call with the body "abc" through `recorder`.
fn startOne(recorder: *RecordingDispatcher, io: std.Io, reply: *FakeReply) !Incoming {
    const head = headOf(get_user);
    const incoming = try accepted(recorder.dispatcher().admit(io, &head, 3));
    @memcpy(incoming.body(), "abc");
    if (incoming.start(io, .init(reply))) |_| return error.TestUnexpectedResult;
    return incoming;
}

fn expectViolations(recorder: *const RecordingDispatcher, expected: []const Violation) !void {
    try testing.expectEqualSlices(Violation, expected, recorder.violations());
}

test "a transport that keeps the rules leaves no violations, and the test sees what it delivered" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    const d = recorder.dispatcher();
    try testing.expectEqual(@as(usize, 1), d.service().routes.len);
    try testing.expectEqual(@as(u32, 4352), d.service().max_inflight);

    // The head is borrowed for the duration of admit only.
    var method = "getUser".*;
    var head = headOf(.{ .service = "users", .version = 1, .method = &method });
    head.metadata = &.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" }, .{ .key = "b", .value = "" } };
    head.peer = .{ .name = "client-7" };
    const incoming = try accepted(d.admit(io, &head, 3));
    method[0] = 'X';
    @memcpy(incoming.body(), "abc");
    var reply: FakeReply = .{};
    try testing.expectEqual(@as(?model.Failure, null), incoming.start(io, .init(&reply)));
    try recorder.waitStarted(io, 1);
    incoming.cancel(io);

    const view = recorder.call(io, 0);
    try testing.expectEqualStrings("getUser", view.head.route.method);
    try testing.expectEqual(@as(usize, 3), view.head.metadata.len);
    try testing.expectEqualStrings("2", view.head.metadata[1].value);
    try testing.expectEqualStrings("", view.head.metadata[2].value);
    try testing.expectEqualStrings("client-7", view.head.peer.name);
    try testing.expectEqualStrings("abc", view.body.?);
    try testing.expectEqual(State.running, view.state);
    try testing.expectEqual(@as(u32, 1), view.cancels);

    try recorder.respond(io, 0, &.{ .status = .ok, .body = "abc" });
    try testing.expectEqualStrings("abc", reply.body[0..reply.len]);
    recorder.releaseCall(io, 0, .completed);
    try testing.expectEqual(Reply.Disposition.completed, reply.released.?);
    try testing.expectEqual(State.released, recorder.call(io, 0).state);

    recorder.close(io);
    try expectViolations(&recorder, &.{});
    const kinds = [_]std.meta.Tag(Event.Kind){ .admit, .start, .cancel, .send, .release };
    try testing.expectEqual(kinds.len, recorder.events().len);
    for (kinds, recorder.events()) |kind, event| {
        try testing.expectEqual(kind, std.meta.activeTag(event.kind));
        try testing.expectEqual(@as(?u32, 0), event.call);
    }
}

test "it refuses as the engine does and counts by route" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{ get_user, list_users }, .max_request_bytes = 8 });
    defer recorder.deinit(io);
    const d = recorder.dispatcher();

    const unknown = headOf(.{ .service = "users", .version = 2, .method = "getUser" });
    try testing.expectEqualStrings("rpc.unknown_method", (try refused(d.admit(io, &unknown, 0))).app_code);
    const head = headOf(get_user);
    // A huge claimed length is refused before anything is allocated for it.
    try testing.expectEqual(core.ErrorCode.resource_exhausted, (try refused(d.admit(io, &head, 1 << 40))).code);
    recorder.setAdmit(io, .{ .reject = .{ .code = .unavailable, .app_code = "test.busy", .message = "Busy" } });
    try testing.expectEqualStrings("test.busy", (try refused(d.admit(io, &head, 1))).app_code);
    recorder.setAdmit(io, .accept);
    (try accepted(d.admit(io, &head, 0))).abandon(io);

    try testing.expectEqual(State.refused, recorder.call(io, 0).state);
    try testing.expectEqualStrings("test.busy", recorder.call(io, 2).refusal.?.app_code);
    try testing.expectEqual(State.abandoned, recorder.call(io, 3).state);
    const stats = d.routeStats(0);
    try testing.expectEqual(@as(u64, 3), stats.requests);
    try testing.expectEqual(@as(u64, 2), stats.errors);
    try testing.expectEqual(@as(u64, 0), d.routeStats(1).requests);
    recorder.close(io);
    try expectViolations(&recorder, &.{});
}

test "start mode fail: start returns the failure and no reply follows" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{
        .routes = &.{get_user},
        .start = .{ .fail = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task" } },
    });
    defer recorder.deinit(io);
    const head = headOf(get_user);
    const incoming = try accepted(recorder.dispatcher().admit(io, &head, 0));
    var reply: FakeReply = .{};
    try testing.expectEqualStrings("No task", incoming.start(io, .init(&reply)).?.message);
    try testing.expectEqual(State.start_failed, recorder.call(io, 0).state);
    recorder.close(io);
    try expectViolations(&recorder, &.{});
    try testing.expectEqual(@as(u32, 0), reply.sends);
    try testing.expectEqual(@as(?Reply.Disposition, null), reply.released);
}

test "an accepted call neither started nor abandoned is caught at close" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    const head = headOf(get_user);
    _ = try accepted(recorder.dispatcher().admit(io, &head, 0));
    recorder.close(io);
    try expectViolations(&recorder, &.{.{ .call = 0, .rule = .unresolved_at_close }});
}

test "a second start, or an abandon after start, is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var reply: FakeReply = .{};
    const incoming = try startOne(&recorder, io, &reply);
    // The second start gets a failure, so the transport has no second call
    // to release.
    try testing.expect(incoming.start(io, .init(&reply)) != null);
    incoming.abandon(io);
    recorder.releaseCall(io, 0, .completed);
    recorder.close(io);
    try expectViolations(&recorder, &.{
        .{ .call = 0, .rule = .start_or_abandon_twice },
        .{ .call = 0, .rule = .start_or_abandon_twice },
    });
}

test "a start before the transport asked for the body is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    const head = headOf(get_user);
    var reply: FakeReply = .{};
    const incoming = try accepted(recorder.dispatcher().admit(io, &head, 3));
    try testing.expectEqual(@as(?model.Failure, null), incoming.start(io, .init(&reply)));
    // An empty body needs no filling.
    const empty = try accepted(recorder.dispatcher().admit(io, &head, 0));
    try testing.expectEqual(@as(?model.Failure, null), empty.start(io, .init(&reply)));
    recorder.releaseCall(io, 0, .completed);
    recorder.releaseCall(io, 1, .completed);
    recorder.close(io);
    try expectViolations(&recorder, &.{.{ .call = 0, .rule = .body_not_filled }});
}

test "a write to the body after start is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var reply: FakeReply = .{};
    const incoming = try startOne(&recorder, io, &reply);
    incoming.body()[1] = 'X';
    recorder.releaseCall(io, 0, .completed);
    recorder.close(io);
    try expectViolations(&recorder, &.{.{ .call = 0, .rule = .body_changed_after_start }});
    try testing.expectEqualStrings("abc", recorder.call(io, 0).body.?);
}

test "a cancel of a call that did not start is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    const head = headOf(get_user);
    const before = try accepted(recorder.dispatcher().admit(io, &head, 0));
    before.cancel(io);
    before.abandon(io);
    before.cancel(io);
    recorder.close(io);
    try expectViolations(&recorder, &.{
        .{ .call = 0, .rule = .cancel_without_start },
        .{ .call = 0, .rule = .cancel_without_start },
    });
}

test "a cancel after release, or after a failed start, is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var reply: FakeReply = .{};
    const released = try startOne(&recorder, io, &reply);
    recorder.releaseCall(io, 0, .completed);
    released.cancel(io);

    recorder.setStart(io, .{ .fail = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task" } });
    const head = headOf(get_user);
    const failed = try accepted(recorder.dispatcher().admit(io, &head, 0));
    try testing.expect(failed.start(io, .init(&reply)) != null);
    failed.cancel(io);
    recorder.close(io);
    try expectViolations(&recorder, &.{
        .{ .call = 0, .rule = .cancel_after_end },
        .{ .call = 1, .rule = .cancel_after_end },
    });
}

test "a call of the transport after close is caught" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var reply: FakeReply = .{};
    const running = try startOne(&recorder, io, &reply);
    recorder.close(io);
    running.cancel(io);
    const head = headOf(get_user);
    try testing.expectEqual(core.ErrorCode.unavailable, (try refused(recorder.dispatcher().admit(io, &head, 0))).code);
    recorder.dispatcher().fail(io, error.Unavailable, null);
    // The engine still answers and releases a call after close.
    try recorder.respond(io, 0, &.{ .status = .ok });
    recorder.releaseCall(io, 0, .canceled);
    try expectViolations(&recorder, &.{
        .{ .call = 0, .rule = .call_after_close },
        .{ .call = 1, .rule = .call_after_close },
        .{ .call = null, .rule = .call_after_close },
    });
}

test "the recorder sends one response, one more only after ResponseTooLarge, and releases once" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var first: FakeReply = .{};
    _ = try startOne(&recorder, io, &first);
    try recorder.respond(io, 0, &.{ .status = .ok, .body = "one" });
    try recorder.respond(io, 0, &.{ .status = .ok, .body = "two" });
    try testing.expectEqual(@as(u32, 1), first.sends);
    recorder.releaseCall(io, 0, .completed);
    recorder.releaseCall(io, 0, .completed);
    try recorder.respond(io, 0, &.{ .status = .ok });

    var too_large_first: FakeReply = .{ .first_send = error.ResponseTooLarge };
    _ = try startOne(&recorder, io, &too_large_first);
    try testing.expectError(error.ResponseTooLarge, recorder.respond(io, 1, &.{ .status = .ok, .body = "huge" }));
    try recorder.respond(io, 1, &.{ .status = .{ .failure = too_large } });
    try recorder.respond(io, 1, &.{ .status = .ok });
    try testing.expectEqual(@as(u32, 2), too_large_first.sends);
    recorder.releaseCall(io, 1, .completed);

    const unknown = headOf(list_users);
    _ = try refused(recorder.dispatcher().admit(io, &unknown, 0));
    try recorder.respond(io, 2, &.{ .status = .ok });
    recorder.close(io);
    try expectViolations(&recorder, &.{
        .{ .call = 0, .rule = .second_send },
        .{ .call = 0, .rule = .reply_after_release },
        .{ .call = 0, .rule = .reply_after_release },
        .{ .call = 1, .rule = .second_send },
        .{ .call = 2, .rule = .reply_without_start },
    });
}

test "fail keeps the first error and its diagnostics" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    try testing.expectEqual(@as(?Fatal, null), recorder.fatal(io));
    var diagnostics: transport.Diagnostics = .{};
    diagnostics.set(.connect, error.ConnectionRefused, "broker at {s} is gone", .{"nats:4222"});
    recorder.dispatcher().fail(io, error.Unavailable, &diagnostics);
    recorder.dispatcher().fail(io, error.Unexpected, null);
    const first = recorder.fatal(io).?;
    try testing.expectEqual(error.Unavailable, first.err);
    try testing.expectEqualStrings("broker at nats:4222 is gone", first.diagnostics.?.message());
    try testing.expectEqual(@as(usize, 2), recorder.events().len);
}

fn startLater(recorder: *RecordingDispatcher, io: std.Io, reply: *FakeReply) !void {
    try io.sleep(.fromMilliseconds(20), .awake);
    _ = try startOne(recorder, io, reply);
}

test "waitStarted waits for a call that another task starts" {
    const io = testing.io;
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    var reply: FakeReply = .{};
    var starter = try io.concurrent(startLater, .{ &recorder, io, &reply });
    defer starter.cancel(io) catch {};
    try recorder.waitStarted(io, 1);
    try starter.await(io);
    try recorder.waitStarted(io, 1);
    recorder.releaseCall(io, 0, .completed);
}

/// A server transport that records the recorder's commands.
const Lifecycle = struct {
    dispatcher: ?Dispatcher = null,
    drains: u32 = 0,
    closes: u32 = 0,

    pub fn start(self: *Lifecycle, io: std.Io, d: Dispatcher) ServerTransport.StartError!void {
        _ = io;
        self.dispatcher = d;
    }
    pub fn drain(self: *Lifecycle, io: std.Io) void {
        _ = io;
        self.drains += 1;
    }
    pub fn close(self: *Lifecycle, io: std.Io) void {
        _ = io;
        self.closes += 1;
    }
    pub fn info(self: *Lifecycle) transport.Info {
        _ = self;
        return .{ .name = "lifecycle" };
    }
};

test "start, drain and close drive the transport; deinit ends the calls left running" {
    const io = testing.io;
    var lifecycle: Lifecycle = .{};
    var reply: FakeReply = .{};
    {
        var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
        defer recorder.deinit(io);
        try recorder.start(io, .init(&lifecycle));
        try testing.expect(lifecycle.dispatcher.?.ptr == @as(*anyopaque, &recorder));
        _ = try startOne(&recorder, io, &reply);
        recorder.drain(io);
        try testing.expectEqual(@as(u32, 1), lifecycle.drains);
    }
    // deinit closed the transport, then released the running call.
    try testing.expectEqual(@as(u32, 1), lifecycle.closes);
    try testing.expectEqual(Reply.Disposition.canceled, reply.released.?);
}
