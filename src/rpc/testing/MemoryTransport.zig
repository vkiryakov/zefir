//! A transport inside one process, for tests: one object is both the client
//! side and the server side. A call goes straight to the
//! `rpc.transport.Dispatcher` the server started with: `admit`, a copy of
//! the body, `start` with a `Reply` that wakes the waiting client. No
//! network and no encoding, so it behaves the same on every run.
//!
//! ```zig
//! var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
//! defer memory.deinit(io); // after the server's deinit and the last call
//! // The server gets memory.serverTransport(), its clients
//! // memory.clientTransport().
//! ```
//!
//! What a client gets:
//!
//! - `error.Unavailable` when no server runs, the server drains or has
//!   closed, or the link is broken: the call surely did not run;
//! - `error.ConnectionLost` when the server closes or the link breaks while
//!   the call waits;
//! - `error.Timeout` at the deadline and `error.Canceled` when its task is
//!   canceled; both cancel the call on the server
//!   (`info().propagates_cancellation`);
//! - a refusal at admission, or a server that cannot start the call, as a
//!   `.failure` response with `refused = true`.
//!
//! `close` waits for calls that are in `admit` or `start` right now; that
//! takes no longer than those functions, which never wait. After `close`, a
//! late `Reply.send` gets `error.Closed`. The transport does not use the
//! `Reply.Disposition` of a call.
//!
//! Hooks for tests of failures, safe to call from any task: `setDelay`
//! holds every call before `admit`, `loseNextResponse` drops a response,
//! `failNext` makes the next call fail, `breakLink` and `restoreLink`
//! break the link in the middle of calls and bring it back, `failServer`
//! tells the server that the whole transport broke.
//!
//! Every call keeps about 100 bytes until `deinit`, so that an engine that
//! breaks the rules of `Reply` gets a panic that names the rule, never a
//! use of freed memory: a second `send` (one more only after
//! `ResponseTooLarge`), `send` after `release`, a second `release`, any
//! `Reply` call after `start` returned a failure, a call not released by
//! `deinit`.
//!
//! The allocator given to `init` must be thread-safe: calls and responses
//! are allocated and freed from the tasks of clients and handlers. The
//! transport stays at one address from `clientTransport` or
//! `serverTransport` until `deinit`.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const ClientTransport = @import("../ClientTransport.zig");
const ServerTransport = @import("../ServerTransport.zig");
const Pending = transport.Pending;
const Reply = transport.Reply;
const Incoming = transport.Incoming;

const MemoryTransport = @This();

gpa: std.mem.Allocator,
options: Options,
pending: Pending,
mutex: std.Io.Mutex = .init,
/// Broadcast when a call leaves `admit` or `start`.
settled: std.Io.Condition = .init,
/// Written under `mutex`; `isReady` reads it without.
state: std.atomic.Value(State) = .init(.idle),
/// The fields below are guarded by `mutex`.
dispatcher: ?transport.Dispatcher = null,
/// The `std.Io` the server started on: `call` checks in Debug that it gets
/// the same.
server_io: ?*const std.Io.VTable = null,
/// Every call from its registration until the server side is done with it:
/// released, refused, abandoned or not started.
calls: std.DoublyLinkedList = .{},
/// The calls the server side is done with; `deinit` frees them.
ended: std.DoublyLinkedList = .{},
/// Calls in `admit` or `start`; `close` waits until there are none.
settling: usize = 0,
/// The hooks; the link is written under `mutex` by `breakLink`.
link_up: std.atomic.Value(bool) = .init(true),
delay_ns: std.atomic.Value(i64) = .init(0),
lose_next: std.atomic.Value(bool) = .init(false),
/// `@intFromError` of the error for the next call; 0 for none.
fail_next: std.atomic.Value(ErrorInt) = .init(0),

const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

/// The errors `failNext` injects: those of `rpc.ClientTransport.call`
/// except `Canceled`, which only a canceled task may get.
pub const InjectedError = error{
    Unavailable,
    AccessDenied,
    ConnectionLost,
    TooManyPendingRequests,
    RequestTooLarge,
    ResponseTooLarge,
    ProtocolViolation,
    UnsupportedProtocol,
    Closed,
    OutOfMemory,
    Unexpected,
    Timeout,
};

pub const Options = struct {
    /// The most calls that wait for their responses at once; more get
    /// `error.TooManyPendingRequests`.
    max_pending: u32 = 1024,
    /// `Info.max_body_bytes`: a larger request body gets
    /// `error.RequestTooLarge` without being sent, and a larger response
    /// body gets `error.ResponseTooLarge` from `Reply.send`. Null: only the
    /// limits of the engine apply.
    max_body_bytes: ?usize = null,
    /// `Peer.name` of every request.
    peer_name: []const u8 = "memory",
};

const State = enum(u8) { idle, running, draining, closed };

/// One call between the client's task and the engine; it lives until the
/// transport's `deinit`.
const Call = struct {
    transport: *MemoryTransport,
    /// In `calls`, then in `ended`.
    node: std.DoublyLinkedList.Node = .{},
    slot: Pending.Slot,
    dispatcher: transport.Dispatcher,
    server_io: *const std.Io.VTable,
    // Guarded by the transport's mutex:
    phase: Phase = .admitting,
    incoming: Incoming = undefined,
    /// The server closed or the link broke: a late send gets `Closed`, and
    /// the client no longer cancels the call.
    cut: bool = false,
    /// The link broke while `start` ran: the client cancels the call once
    /// `start` has returned.
    cancel_pending: bool = false,
    /// The transport has canceled the call on the server, and does not
    /// again.
    canceled: bool = false,
    sends: u8 = 0,
    retry_allowed: bool = false,

    const Phase = enum {
        admitting,
        starting,
        running,
        released,
        /// Refused at admission, abandoned, or its `start` returned a
        /// failure: no `Reply` call may come.
        not_started,
    };

    /// Hands the response to the waiting client: a copy, since `response`
    /// is borrowed. A response for a client that has given up is dropped.
    pub fn send(c: *Call, io: std.Io, response: *const model.Response) Reply.SendError!void {
        const t = c.transport;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        {
            t.mutex.lockUncancelable(io);
            defer t.mutex.unlock(io);
            switch (c.phase) {
                .released => @panic("rpc.testing.MemoryTransport: send called after release; release is the last call of a Reply"),
                .not_started => @panic(failed_start),
                .admitting, .starting, .running => {},
            }
            if (c.sends > 0 and !c.retry_allowed)
                @panic("rpc.testing.MemoryTransport: send called again for one call; send at most once, or once more after ResponseTooLarge");
            c.sends += 1;
            c.retry_allowed = false;
            if (t.options.max_body_bytes) |max| if (response.body.len > max) {
                c.retry_allowed = c.sends == 1;
                return error.ResponseTooLarge;
            };
        }
        const message = try Message.create(t.gpa, response);
        const delivered, const closed = delivered: {
            t.mutex.lockUncancelable(io);
            defer t.mutex.unlock(io);
            if (c.cut) break :delivered .{ false, true };
            if (t.lose_next.swap(false, .monotonic)) break :delivered .{ false, false };
            break :delivered .{ t.pending.complete(io, c.slot.id, message.delivery()), false };
        };
        if (!delivered) message.destroy();
        if (closed) return error.Closed;
    }

    /// The engine is done with the call: it leaves the calls in flight.
    pub fn release(c: *Call, io: std.Io, disposition: Reply.Disposition) void {
        _ = disposition;
        const t = c.transport;
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        switch (c.phase) {
            .released => @panic("rpc.testing.MemoryTransport: release called twice for one call; release each call once"),
            .not_started => @panic(failed_start),
            .admitting, .starting, .running => {},
        }
        c.phase = .released;
        t.end(c);
    }
};

const failed_start = "rpc.testing.MemoryTransport: Reply called after start returned a failure; no Reply call follows a failed start";

/// A response on its way from `Reply.send` to the client, in memory of the
/// transport's allocator.
const Message = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    response: model.Response,

    fn create(gpa: std.mem.Allocator, response: *const model.Response) error{OutOfMemory}!*Message {
        const m = try gpa.create(Message);
        m.* = .{ .gpa = gpa, .arena = .init(gpa), .response = undefined };
        errdefer m.destroy();
        m.response = try cloneResponse(m.arena.allocator(), response.*);
        return m;
    }

    fn destroy(m: *Message) void {
        m.arena.deinit();
        m.gpa.destroy(m);
    }

    fn free(context: *anyopaque) void {
        const m: *Message = @ptrCast(@alignCast(context));
        m.destroy();
    }

    fn delivery(m: *Message) Pending.Delivery {
        return .{ .response = m.response, .context = m, .release = free };
    }
};

/// Takes the memory for `options.max_pending` waiting calls.
pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!MemoryTransport {
    return .{ .gpa = gpa, .options = options, .pending = try .init(gpa, .{ .max_pending = options.max_pending }) };
}

/// Frees the transport, after the server's `deinit` and after the last
/// `call` has returned. Panics while a call is not released: the server
/// still holds its `Reply`.
pub fn deinit(t: *MemoryTransport, io: std.Io) void {
    t.mutex.lockUncancelable(io);
    if (t.calls.first != null) @panic("rpc.testing.MemoryTransport: deinit with calls not released; deinit the server and let every call return first");
    t.mutex.unlock(io);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    while (t.ended.popFirst()) |node| {
        const c: *Call = @fieldParentPtr("node", node);
        t.gpa.destroy(c);
    }
    t.pending.deinit();
    t.* = undefined;
}

/// The client side, for the engine of the client.
pub fn clientTransport(t: *MemoryTransport) ClientTransport {
    return .init(t);
}

/// The server side, for the engine of the server.
pub fn serverTransport(t: *MemoryTransport) ServerTransport {
    return .init(t);
}

/// The same for both sides.
pub fn info(t: *MemoryTransport) transport.Info {
    return .{
        .name = "memory",
        .propagates_cancellation = true,
        .reports_unprocessed = true,
        .reports_connection_loss = true,
        .max_body_bytes = t.options.max_body_bytes,
    };
}

/// Sends `request` to the server's dispatcher and waits for the response,
/// by the rules of `rpc.ClientTransport.call`.
pub fn call(t: *MemoryTransport, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions) ClientTransport.CallError!model.Response {
    // A cancelation pending on entry comes before any other error.
    try io.checkCancel();
    if (t.takeInjected()) |err| {
        if (options.diagnostics) |d| d.set(.send, err, "error injected with failNext", .{});
        return err;
    }
    if (!t.serving()) return error.Unavailable;
    if (t.options.max_body_bytes) |max| if (request.body.len > max) {
        if (options.diagnostics) |d| d.set(.send, null, "request body of {d} bytes is over max_body_bytes {d}", .{ request.body.len, max });
        return error.RequestTooLarge;
    };
    const deadline = request.ctx.deadline;
    if (deadline) |d| if (d.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return error.Timeout;
    const delay_ns = t.delay_ns.load(.monotonic);
    if (delay_ns > 0) {
        // Never past the deadline: then Timeout comes on time.
        var pause: std.Io.Duration = .fromNanoseconds(delay_ns);
        if (deadline) |d| pause.nanoseconds = @min(pause.nanoseconds, d.remaining(now(io)).nanoseconds);
        try io.sleep(pause, .awake);
        if (deadline) |d| if (d.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return error.Timeout;
    }

    const c = try t.register(io);
    defer t.releaseSlot(io, c.slot);
    if (std.debug.runtime_safety and c.server_io != io.vtable)
        @panic("rpc.testing.MemoryTransport: call with another std.Io than the server's; pass the io the server started on");

    const sent_at = now(io);
    const head: transport.RequestHead = .{
        .route = request.route,
        .request_id = request.request_id,
        .codec = request.codec,
        .timeout = if (deadline) |d| d.remaining(sent_at) else null,
        .received_at = sent_at,
        .metadata = request.metadata,
        .peer = .{ .name = t.options.peer_name },
    };
    switch (c.dispatcher.admit(io, &head, request.body.len)) {
        .rejected => |failure| {
            t.forget(io, c);
            return refusal(io, options, failure);
        },
        .accepted => |incoming| {
            @memcpy(incoming.body(), request.body);
            if (!t.beginStart(io, c, incoming)) {
                // The server closed or the link broke during admit: the
                // call will not start.
                incoming.abandon(io);
                t.forget(io, c);
                return error.Unavailable;
            }
            if (incoming.start(io, .init(c))) |failure| {
                t.forget(io, c);
                return refusal(io, options, failure);
            }
            t.endStart(io, c);
        },
    }

    const delivery = t.pending.wait(io, c.slot, deadline orelse .after(sent_at, .max)) catch |err| {
        switch (err) {
            // The client gave up: tell the server.
            error.Canceled, error.Timeout => t.cancelCall(io, c),
            error.ConnectionLost, error.Closed => {},
        }
        return err;
    };
    defer freeDelivery(io, delivery);
    return copyResponse(io, options, delivery.response);
}

/// Takes calls from here on: `call` hands them to `dispatcher`. A second
/// `start` while a server runs gets `error.AddressInUse`; after `close`
/// the transport may start again.
pub fn start(t: *MemoryTransport, io: std.Io, dispatcher: transport.Dispatcher) ServerTransport.StartError!void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    switch (t.state.load(.monotonic)) {
        .running, .draining => return error.AddressInUse,
        .idle, .closed => {},
    }
    t.dispatcher = dispatcher;
    t.server_io = io.vtable;
    t.state.store(.running, .release);
}

/// New calls get `error.Unavailable`; calls already on their way go on.
pub fn drain(t: *MemoryTransport, io: std.Io) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    if (t.state.load(.monotonic) == .running) t.state.store(.draining, .release);
}

/// Stops the server side: new calls get `error.Unavailable`, waiting
/// clients `error.ConnectionLost`, a late `Reply.send` `error.Closed`.
/// Waits for the calls in `admit` or `start`: a call the server accepted
/// is started or abandoned before `close` returns, a second `close` too.
/// Calls already started stay with the engine until their `Reply.release`.
pub fn close(t: *MemoryTransport, io: std.Io) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    switch (t.state.load(.monotonic)) {
        .idle => return,
        // A second close waits too, for the calls the first one waits for.
        .closed => {},
        .running, .draining => {
            t.state.store(.closed, .release);
            t.dispatcher = null;
            var node = t.calls.first;
            while (node) |n| : (node = n.next) {
                const c: *Call = @fieldParentPtr("node", n);
                c.cut = true;
            }
            t.pending.failAll(io, error.ConnectionLost);
        },
    }
    while (t.settling > 0) t.settled.waitUncancelable(io, &t.mutex);
}

/// Running, not draining, and the link is up.
pub fn isReady(t: *MemoryTransport) bool {
    return t.serving();
}

/// Holds every call for `delay` before it goes to the server, as a slow
/// network would; never past the call's deadline. `.zero` turns it off.
pub fn setDelay(t: *MemoryTransport, delay: std.Io.Duration) void {
    t.delay_ns.store(@intCast(std.math.clamp(delay.nanoseconds, 0, std.math.maxInt(i64))), .monotonic);
}

/// The next `Reply.send` succeeds, but its response never reaches the
/// client, which gets `error.Timeout` at its deadline.
pub fn loseNextResponse(t: *MemoryTransport) void {
    t.lose_next.store(true, .monotonic);
}

/// The next call returns `err` at once, without sending, with a message in
/// its `Diagnostics`.
pub fn failNext(t: *MemoryTransport, err: InjectedError) void {
    t.fail_next.store(@intFromError(err), .monotonic);
}

/// Breaks the link between the clients and the server in the middle of
/// calls: waiting clients get `error.ConnectionLost`, the server gets
/// `Incoming.cancel` for every call it runs, a late `Reply.send` gets
/// `error.Closed`, and new calls get `error.Unavailable` until
/// `restoreLink`. A call in `start` right now is canceled once `start`
/// returns.
pub fn breakLink(t: *MemoryTransport, io: std.Io) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    t.link_up.store(false, .release);
    var node = t.calls.first;
    while (node) |n| : (node = n.next) {
        const c: *Call = @fieldParentPtr("node", n);
        if (c.cut) continue;
        c.cut = true;
        switch (c.phase) {
            // Its client sees the cut after admit and abandons it.
            .admitting => {},
            .starting => c.cancel_pending = true,
            .running => cancelOnServer(c, io),
            // Calls the server side is done with leave the list.
            .released, .not_started => unreachable,
        }
    }
    t.pending.failAll(io, error.ConnectionLost);
}

/// New calls go through again. Calls cut by `breakLink` stay cut: their
/// late responses get `error.Closed`.
pub fn restoreLink(t: *MemoryTransport) void {
    t.link_up.store(true, .release);
}

/// Tells the running server that the transport broke for good, as a
/// transport whose port died would: `Dispatcher.fail(err)` with a message
/// in its `Diagnostics`. Nothing else changes; the engine drains and
/// closes. Without a running or draining server it does nothing.
pub fn failServer(t: *MemoryTransport, io: std.Io, err: transport.Dispatcher.FatalError) void {
    const dispatcher = dispatcher: {
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        switch (t.state.load(.monotonic)) {
            .running, .draining => {},
            .idle, .closed => return,
        }
        // `close` waits for it, as for a call in admit.
        t.settling += 1;
        break :dispatcher t.dispatcher.?;
    };
    var diagnostics: transport.Diagnostics = .{};
    diagnostics.set(.connect, err, "failure injected with failServer", .{});
    // Outside the lock: the engine may drain the transport right away.
    dispatcher.fail(io, err, &diagnostics);
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    t.settle(io);
}

/// A server runs, does not drain, and the link is up.
fn serving(t: *MemoryTransport) bool {
    return t.state.load(.acquire) == .running and t.link_up.load(.acquire);
}

fn takeInjected(t: *MemoryTransport) ?InjectedError {
    const value = t.fail_next.swap(0, .monotonic);
    if (value == 0) return null;
    return @errorCast(@errorFromInt(value));
}

/// A new call with a slot for its response, recorded before `admit`.
fn register(t: *MemoryTransport, io: std.Io) ClientTransport.CallError!*Call {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const c = try t.gpa.create(Call);
    errdefer t.gpa.destroy(c);
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    if (!t.serving()) return error.Unavailable;
    c.* = .{
        .transport = t,
        .slot = try t.pending.acquire(io),
        .dispatcher = t.dispatcher.?,
        .server_io = t.server_io.?,
    };
    t.calls.append(&c.node);
    t.settling += 1;
    return c;
}

/// The call leaves `admit` or `start` without running: refused,
/// abandoned, or its `start` returned a failure.
fn forget(t: *MemoryTransport, io: std.Io, c: *Call) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    // The engine released a call whose start then returned a failure.
    if (c.phase == .released) @panic(failed_start);
    c.phase = .not_started;
    t.end(c);
    t.settle(io);
}

/// The server side is done with `c`; under `mutex`.
fn end(t: *MemoryTransport, c: *Call) void {
    t.calls.remove(&c.node);
    t.ended.append(&c.node);
}

/// False when the server closed or the link broke while the call was in
/// `admit`.
fn beginStart(t: *MemoryTransport, io: std.Io, c: *Call, incoming: Incoming) bool {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    if (c.cut) return false;
    c.incoming = incoming;
    c.phase = .starting;
    return true;
}

/// `start` returned null: the call runs, unless it was released already.
fn endStart(t: *MemoryTransport, io: std.Io, c: *Call) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    t.settle(io);
    if (c.phase == .released) return;
    c.phase = .running;
    if (c.cancel_pending) cancelOnServer(c, io);
}

/// The client gave up on a running call: cancel it on the server, unless
/// the engine released it or the server closed.
fn cancelCall(t: *MemoryTransport, io: std.Io, c: *Call) void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    if (c.phase == .running and !c.cut) cancelOnServer(c, io);
}

/// `Incoming.cancel`, once a call; under `mutex`.
fn cancelOnServer(c: *Call, io: std.Io) void {
    if (c.canceled) return;
    c.canceled = true;
    c.incoming.cancel(io);
}

/// One call fewer in `admit` or `start`; under `mutex`.
fn settle(t: *MemoryTransport, io: std.Io) void {
    t.settling -= 1;
    if (t.settling == 0) t.settled.broadcast(io);
}

/// `Pending.release`, which may free a response that came too late.
fn releaseSlot(t: *MemoryTransport, io: std.Io, slot: Pending.Slot) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    t.pending.release(io, slot);
}

fn freeDelivery(io: std.Io, delivery: Pending.Delivery) void {
    // Allocator work: a Debug allocator that captures a stack trace takes
    // a cancelable lock, and would swallow a cancelation of the task.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    delivery.release(delivery.context);
}

/// The response a client gets for a refusal: the call did not run.
fn refusal(io: std.Io, options: ClientTransport.CallOptions, failure: model.Failure) ClientTransport.CallError!model.Response {
    return copyResponse(io, options, .{ .status = .{ .failure = failure }, .refused = true });
}

/// A copy of `response` in `options.allocator`, within its limits.
fn copyResponse(io: std.Io, options: ClientTransport.CallOptions, response: model.Response) ClientTransport.CallError!model.Response {
    if (response.body.len > options.max_response_bytes) {
        if (options.diagnostics) |d| d.set(.receive, null, "response body of {d} bytes is over max_response_bytes {d}", .{ response.body.len, options.max_response_bytes });
        return error.ResponseTooLarge;
    }
    const metadata_bytes = transport.metadataBytes(response.metadata);
    if (response.metadata.len > options.max_response_metadata_entries or metadata_bytes > options.max_response_metadata_bytes) {
        if (options.diagnostics) |d| d.set(.receive, null, "response metadata of {d} entries and {d} bytes is over the limits of {d} and {d}", .{
            response.metadata.len,
            metadata_bytes,
            options.max_response_metadata_entries,
            options.max_response_metadata_bytes,
        });
        return error.ResponseTooLarge;
    }
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return cloneResponse(options.allocator, response);
}

/// A deep copy of `response` in `a`: the metadata, the body and the
/// strings of a failure. Not the violations: on every transport they
/// travel in the body.
fn cloneResponse(a: std.mem.Allocator, response: model.Response) error{OutOfMemory}!model.Response {
    const metadata = try cloneMetadata(a, response.metadata);
    errdefer freeMetadata(a, metadata);
    const body = try a.dupe(u8, response.body);
    errdefer a.free(body);
    const status: model.Status = switch (response.status) {
        .ok => .ok,
        .failure => |failure| .{ .failure = try cloneFailure(a, failure) },
    };
    return .{ .status = status, .metadata = metadata, .body = body, .refused = response.refused };
}

fn cloneMetadata(a: std.mem.Allocator, entries: []const model.Metadata.Entry) error{OutOfMemory}![]model.Metadata.Entry {
    const copy = try a.alloc(model.Metadata.Entry, entries.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |entry| {
            a.free(entry.key);
            a.free(entry.value);
        }
        a.free(copy);
    }
    for (entries, copy) |entry, *slot| {
        const key = try a.dupe(u8, entry.key);
        errdefer a.free(key);
        slot.* = .{ .key = key, .value = try a.dupe(u8, entry.value) };
        done += 1;
    }
    return copy;
}

fn freeMetadata(a: std.mem.Allocator, entries: []const model.Metadata.Entry) void {
    for (entries) |entry| {
        a.free(entry.key);
        a.free(entry.value);
    }
    a.free(entries);
}

fn cloneFailure(a: std.mem.Allocator, failure: model.Failure) error{OutOfMemory}!model.Failure {
    const app_code = try a.dupe(u8, failure.app_code);
    errdefer a.free(app_code);
    const message = try a.dupe(u8, failure.message);
    errdefer a.free(message);
    const field = if (failure.field) |field| try a.dupe(u8, field) else null;
    return .{ .code = failure.code, .app_code = app_code, .message = message, .field = field };
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

const testing = std.testing;
const RecordingDispatcher = @import("RecordingDispatcher.zig");

const get_user: model.Route = .{ .service = "users", .version = 1, .method = "getUser" };

fn requestOf(io: std.Io, body: []const u8, budget: std.Io.Duration) transport.Request {
    return .{
        .route = get_user,
        .request_id = @splat(5),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(now(io), budget)),
        .metadata = &.{},
        .body = body,
    };
}

/// A memory transport with a recording server, for the tests below.
const Fixture = struct {
    memory: MemoryTransport,
    recorder: RecordingDispatcher,

    fn init(f: *Fixture, io: std.Io, options: Options, recorder_options: RecordingDispatcher.Options) !void {
        f.memory = try .init(testing.allocator, options);
        errdefer f.memory.deinit(io);
        f.recorder = try .init(testing.allocator, recorder_options);
        errdefer f.recorder.deinit(io);
        try f.recorder.start(io, f.memory.serverTransport());
    }

    fn deinit(f: *Fixture, io: std.Io) void {
        f.recorder.deinit(io);
        f.memory.deinit(io);
    }

    /// Closes the server and checks that the transport kept its rules.
    fn expectClean(f: *Fixture, io: std.Io) !void {
        f.recorder.close(io);
        try testing.expectEqualSlices(RecordingDispatcher.Violation, &.{}, f.recorder.violations());
    }
};

fn callTask(client: ClientTransport, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions) ClientTransport.CallError!model.Response {
    return client.call(io, request, options);
}

fn optionsOf(arena: *std.heap.ArenaAllocator) ClientTransport.CallOptions {
    return .{ .allocator = arena.allocator(), .max_response_bytes = 1024 };
}

fn expectFailure(response: model.Response, app_code: []const u8) !void {
    switch (response.status) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqualStrings(app_code, failure.app_code),
    }
}

test "a call reaches the server's dispatcher and its response comes back byte for byte" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    const client = f.memory.clientTransport();
    const info_ = client.info();
    try testing.expectEqualStrings("memory", info_.name);
    try testing.expect(info_.propagates_cancellation and info_.reports_unprocessed and info_.reports_connection_loss);
    try testing.expectEqual(@as(?usize, null), info_.max_body_bytes);
    try testing.expect(f.memory.serverTransport().isReady());

    const body = "\x00\xff\xfe{not utf-8}";
    const metadata = [_]model.Metadata.Entry{
        .{ .key = "x-a", .value = "1" },
        .{ .key = "x-a", .value = "2" },
        .{ .key = "x-b", .value = "" },
        .{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" },
    };
    var request = requestOf(io, body, .fromSeconds(5));
    request.metadata = &metadata;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var caller = try io.concurrent(callTask, .{ client, io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};

    try f.recorder.waitStarted(io, 1);
    const view = try f.recorder.call(io, 0);
    try testing.expectEqualStrings(body, view.body.?);
    try testing.expectEqualStrings("getUser", view.head.route.method);
    try testing.expectEqual(request.request_id, view.head.request_id);
    try testing.expectEqualStrings("json", view.head.codec);
    try testing.expectEqualStrings("memory", view.head.peer.name);
    try testing.expectEqual(metadata.len, view.head.metadata.len);
    for (metadata, view.head.metadata) |sent, got| {
        try testing.expectEqualStrings(sent.key, got.key);
        try testing.expectEqualStrings(sent.value, got.value);
    }
    // The budget left, measured right before the call went to the server.
    const timeout = view.head.timeout.?;
    try testing.expect(timeout.nanoseconds > 0 and timeout.nanoseconds <= std.time.ns_per_s * 5);
    try testing.expect(view.head.received_at.nanoseconds > 0);

    const response_metadata = [_]model.Metadata.Entry{ .{ .key = "x-r", .value = "v" }, .{ .key = "x-r", .value = "" } };
    try f.recorder.respond(io, 0, &.{ .status = .ok, .body = body, .metadata = &response_metadata });
    try f.recorder.releaseCall(io, 0, .completed);
    const response = try caller.await(io);
    try testing.expect(response.status == .ok);
    try testing.expect(!response.refused);
    try testing.expectEqualStrings(body, response.body);
    try testing.expectEqual(@as(usize, 2), response.metadata.len);
    try testing.expectEqualStrings("x-r", response.metadata[1].key);
    try testing.expectEqualStrings("", response.metadata[1].value);

    // An empty body both ways.
    const empty = requestOf(io, "", .fromSeconds(5));
    var second = try io.concurrent(callTask, .{ client, io, &empty, optionsOf(&arena) });
    defer if (second.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 2);
    try testing.expectEqualStrings("", (try f.recorder.call(io, 1)).body.?);
    try f.recorder.respond(io, 1, &.{ .status = .ok });
    try f.recorder.releaseCall(io, 1, .completed);
    try testing.expectEqualStrings("", (try second.await(io)).body);
    try f.expectClean(io);
}

test "a refusal at admission or at start comes as a failure with refused" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{
        .routes = &.{get_user},
        .admit = .{ .reject = .{ .code = .unavailable, .app_code = "test.draining", .message = "Draining" } },
    });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request = requestOf(io, "{}", .fromSeconds(5));

    const refused_at_admit = try f.memory.call(io, &request, optionsOf(&arena));
    try expectFailure(refused_at_admit, "test.draining");
    try testing.expect(refused_at_admit.refused);

    f.recorder.setAdmit(io, .accept);
    f.recorder.setStart(io, .{ .fail = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task" } });
    const refused_at_start = try f.memory.call(io, &request, optionsOf(&arena));
    try expectFailure(refused_at_start, "rpc.resource_exhausted");
    try testing.expect(refused_at_start.refused);
    try testing.expectEqual(RecordingDispatcher.State.start_failed, (try f.recorder.call(io, 1)).state);

    f.recorder.setStart(io, .run);
    var unknown = request;
    unknown.route.method = "deleteUser";
    const unknown_route = try f.memory.call(io, &unknown, optionsOf(&arena));
    try expectFailure(unknown_route, "rpc.unknown_method");
    try testing.expect(unknown_route.refused);
    try f.expectClean(io);
}

test "the deadline gives Timeout and cancels the call on the server; a late response is dropped" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromMilliseconds(50));
    try testing.expectError(error.Timeout, f.memory.call(io, &request, optionsOf(&arena)));
    try testing.expect(request.ctx.deadline.?.isExpired(now(io)));
    try testing.expectEqual(@as(u32, 1), (try f.recorder.call(io, 0)).cancels);
    // The handler answers late: the response goes nowhere.
    try f.recorder.respond(io, 0, &.{ .status = .ok, .body = "late" });
    try f.recorder.releaseCall(io, 0, .canceled);

    // Less than 1 ms left: not sent at all.
    const expired = requestOf(io, "{}", .fromMicroseconds(500));
    try testing.expectError(error.Timeout, f.memory.call(io, &expired, optionsOf(&arena)));
    try testing.expectEqual(@as(u64, 1), f.recorder.dispatcher().routeStats(0).requests);
    try f.expectClean(io);
}

test "canceling the client's task gives Canceled once and cancels the call on the server" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    try f.recorder.waitStarted(io, 1);
    try testing.expectError(error.Canceled, caller.cancel(io));
    try testing.expectEqual(@as(u32, 1), (try f.recorder.call(io, 0)).cancels);
    try f.recorder.releaseCall(io, 0, .canceled);
    try f.expectClean(io);
}

test "a response over the caller's limits gives ResponseTooLarge" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { model.Response, []const u8 }{
        .{ .{ .status = .ok, .body = "123456789" }, "response body of 9 bytes is over max_response_bytes 8" },
        .{ .{ .status = .ok, .metadata = &.{ .{ .key = "a", .value = "" }, .{ .key = "b", .value = "" }, .{ .key = "c", .value = "" } } }, "response metadata of 3 entries and 14 bytes is over the limits of 2 and 1024" },
        .{ .{ .status = .ok, .metadata = &.{.{ .key = "a", .value = &@as([1024]u8, @splat('v')) }} }, "response metadata of 1 entries and 1030 bytes is over the limits of 2 and 1024" },
    };
    const request = requestOf(io, "{}", .fromSeconds(5));
    for (cases, 0..) |case, i| {
        var diagnostics: transport.Diagnostics = .{};
        var options = optionsOf(&arena);
        options.max_response_bytes = 8;
        options.max_response_metadata_entries = 2;
        options.max_response_metadata_bytes = 1024;
        options.diagnostics = &diagnostics;
        var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, options });
        defer if (caller.cancel(io)) |_| {} else |_| {};
        try f.recorder.waitStarted(io, i + 1);
        try f.recorder.respond(io, i, &case[0]);
        try f.recorder.releaseCall(io, i, .completed);
        try testing.expectError(error.ResponseTooLarge, caller.await(io));
        try testing.expectEqualStrings(case[1], diagnostics.message());
        try testing.expectEqual(transport.Diagnostics.Phase.receive, diagnostics.phase.?);
    }
    try f.expectClean(io);
}

test "max_body_bytes: a larger request is not sent, a larger response is refused to the engine" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{ .max_body_bytes = 4 }, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?usize, 4), f.memory.clientTransport().info().max_body_bytes);

    var diagnostics: transport.Diagnostics = .{};
    var options = optionsOf(&arena);
    options.diagnostics = &diagnostics;
    const too_large = requestOf(io, "abcde", .fromSeconds(5));
    try testing.expectError(error.RequestTooLarge, f.memory.call(io, &too_large, options));
    try testing.expectEqualStrings("request body of 5 bytes is over max_body_bytes 4", diagnostics.message());
    try testing.expectEqual(@as(u64, 0), f.recorder.dispatcher().routeStats(0).requests);

    // At the limit it goes; the engine's large response is refused, and a
    // small failure in its place is allowed.
    const at_limit = requestOf(io, "abcd", .fromSeconds(5));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &at_limit, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try testing.expectEqualStrings("abcd", (try f.recorder.call(io, 0)).body.?);
    try testing.expectError(error.ResponseTooLarge, f.recorder.respond(io, 0, &.{ .status = .ok, .body = "12345" }));
    try f.recorder.respond(io, 0, &.{ .status = .{ .failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Response too large" } } });
    try f.recorder.releaseCall(io, 0, .completed);
    try expectFailure(try caller.await(io), "rpc.resource_exhausted");
    try f.expectClean(io);
}

test "no server, a draining server and a closed one give Unavailable" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request = requestOf(io, "{}", .fromSeconds(5));
    try testing.expectError(error.Unavailable, memory.call(io, &request, optionsOf(&arena)));
    try testing.expect(!memory.isReady());

    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user} });
    defer recorder.deinit(io);
    try recorder.start(io, memory.serverTransport());
    try testing.expect(memory.isReady());

    // A call on its way when drain comes still gets its response.
    var caller = try io.concurrent(callTask, .{ memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try recorder.waitStarted(io, 1);
    recorder.drain(io);
    recorder.drain(io);
    try testing.expect(!memory.isReady());
    try testing.expectError(error.Unavailable, memory.call(io, &request, optionsOf(&arena)));
    try recorder.respond(io, 0, &.{ .status = .ok, .body = "done" });
    try recorder.releaseCall(io, 0, .completed);
    try testing.expectEqualStrings("done", (try caller.await(io)).body);

    recorder.close(io);
    try testing.expectError(error.Unavailable, memory.call(io, &request, optionsOf(&arena)));
    try testing.expectEqualSlices(RecordingDispatcher.Violation, &.{}, recorder.violations());
}

test "close: a waiting client gets ConnectionLost, a late send gets Closed" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    f.recorder.close(io);
    try testing.expectError(error.ConnectionLost, caller.await(io));
    // The engine still answers and releases the call after close.
    try testing.expectError(error.Closed, f.recorder.respond(io, 0, &.{ .status = .ok }));
    try f.recorder.releaseCall(io, 0, .canceled);
    try f.expectClean(io);
}

test "a second server gets AddressInUse; after close the transport starts again" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var first: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user}, .start = .{ .fail = .{ .code = .unavailable, .app_code = "test.first", .message = "First" } } });
    defer first.deinit(io);
    var second: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{get_user}, .start = .{ .fail = .{ .code = .unavailable, .app_code = "test.second", .message = "Second" } } });
    defer second.deinit(io);
    const request = requestOf(io, "{}", .fromSeconds(5));

    try first.start(io, memory.serverTransport());
    try testing.expectError(error.AddressInUse, second.start(io, memory.serverTransport()));
    // The failed start changed nothing: calls still go to the first server.
    try expectFailure(try memory.call(io, &request, optionsOf(&arena)), "test.first");

    first.close(io);
    try second.start(io, memory.serverTransport());
    try expectFailure(try memory.call(io, &request, optionsOf(&arena)), "test.second");
    second.close(io);
    try testing.expectEqualSlices(RecordingDispatcher.Violation, &.{}, first.violations());
    try testing.expectEqualSlices(RecordingDispatcher.Violation, &.{}, second.violations());
}

test "max_pending calls wait at once; one more gets TooManyPendingRequests" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{ .max_pending = 1 }, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(5));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try testing.expectError(error.TooManyPendingRequests, f.memory.call(io, &request, optionsOf(&arena)));
    try f.recorder.respond(io, 0, &.{ .status = .ok });
    try f.recorder.releaseCall(io, 0, .completed);
    _ = try caller.await(io);
    try testing.expectEqual(@as(u64, 1), f.recorder.dispatcher().routeStats(0).requests);
    try f.expectClean(io);
}

fn freeResponse(a: std.mem.Allocator, response: model.Response) void {
    freeMetadata(a, response.metadata);
    a.free(response.body);
    switch (response.status) {
        .ok => {},
        .failure => |failure| {
            a.free(failure.app_code);
            a.free(failure.message);
            if (failure.field) |field| a.free(field);
        },
    }
}

fn cloneAndFree(a: std.mem.Allocator) !void {
    const response: model.Response = .{
        .status = .{ .failure = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found", .field = "id" } },
        .metadata = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" } },
        .body = "{}",
        .refused = true,
    };
    const copy = try cloneResponse(a, response);
    defer freeResponse(a, copy);
    try testing.expectEqualStrings("User not found", copy.status.failure.message);
    try testing.expectEqualStrings("id", copy.status.failure.field.?);
    try testing.expectEqualStrings("2", copy.metadata[1].value);
    try testing.expect(copy.refused);
}

test "a copy of a response frees what it took when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, cloneAndFree, .{});
}

test "setDelay holds a call before admit; the deadline still comes on time" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    f.memory.setDelay(.fromMilliseconds(50));
    const request = requestOf(io, "{}", .fromSeconds(5));
    const sent = now(io);
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try testing.expect(sent.durationTo((try f.recorder.call(io, 0)).head.received_at).nanoseconds >= 50 * std.time.ns_per_ms);
    try f.recorder.respond(io, 0, &.{ .status = .ok });
    try f.recorder.releaseCall(io, 0, .completed);
    _ = try caller.await(io);

    // A delay past the deadline: Timeout at the deadline, nothing sent.
    f.memory.setDelay(.fromSeconds(5));
    const short = requestOf(io, "{}", .fromMilliseconds(60));
    const started = now(io);
    try testing.expectError(error.Timeout, f.memory.call(io, &short, optionsOf(&arena)));
    try testing.expect(short.ctx.deadline.?.isExpired(now(io)));
    try testing.expect(started.durationTo(now(io)).nanoseconds < std.time.ns_per_s * 4);

    // The delay is a cancelation point.
    var canceled = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, canceled.cancel(io));

    f.memory.setDelay(.zero);
    try testing.expectEqual(@as(u64, 1), f.recorder.dispatcher().routeStats(0).requests);
    try f.expectClean(io);
}

test "loseNextResponse: the send succeeds and the client gets Timeout" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    f.memory.loseNextResponse();
    const request = requestOf(io, "{}", .fromMilliseconds(100));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try f.recorder.respond(io, 0, &.{ .status = .ok, .body = "lost" });
    try f.recorder.releaseCall(io, 0, .completed);
    try testing.expectError(error.Timeout, caller.await(io));

    // Only the next response is lost.
    const next = requestOf(io, "{}", .fromSeconds(5));
    var second = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &next, optionsOf(&arena) });
    defer if (second.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 2);
    try f.recorder.respond(io, 1, &.{ .status = .ok, .body = "found" });
    try f.recorder.releaseCall(io, 1, .completed);
    try testing.expectEqualStrings("found", (try second.await(io)).body);
    try f.expectClean(io);
}

test "failNext: the next call gets the error once, with diagnostics" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user}, .admit = .{ .reject = .{ .code = .unavailable, .app_code = "test.reached", .message = "Reached" } } });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var diagnostics: transport.Diagnostics = .{};
    var options = optionsOf(&arena);
    options.diagnostics = &diagnostics;
    const request = requestOf(io, "{}", .fromSeconds(5));
    f.memory.failNext(error.Unexpected);
    try testing.expectError(error.Unexpected, f.memory.call(io, &request, options));
    try testing.expectEqual(error.Unexpected, diagnostics.cause.?);
    try testing.expectEqualStrings("error injected with failNext", diagnostics.message());
    try testing.expectEqual(@as(u64, 0), f.recorder.dispatcher().routeStats(0).requests);
    try expectFailure(try f.memory.call(io, &request, options), "test.reached");

    // Any error of call but Canceled, which only a canceled task gets.
    f.memory.failNext(error.Timeout);
    try testing.expectError(error.Timeout, f.memory.call(io, &request, options));
    const call_errors = @typeInfo(ClientTransport.CallError).error_set.error_names.?;
    const injected = @typeInfo(InjectedError).error_set.error_names.?;
    try testing.expectEqual(call_errors.len - 1, injected.len);
    for (call_errors) |name| {
        if (std.mem.eql(u8, name, "Canceled")) continue;
        for (injected) |other| {
            if (std.mem.eql(u8, name, other)) break;
        } else return error.TestUnexpectedResult;
    }
    try f.expectClean(io);
}

test "breakLink: waiting clients get ConnectionLost and the server cancels their calls; restoreLink brings calls back" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var first = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (first.cancel(io)) |_| {} else |_| {};
    var second = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (second.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 2);

    f.memory.breakLink(io);
    try testing.expectError(error.ConnectionLost, first.await(io));
    try testing.expectError(error.ConnectionLost, second.await(io));
    try testing.expectEqual(@as(u32, 1), (try f.recorder.call(io, 0)).cancels);
    try testing.expectEqual(@as(u32, 1), (try f.recorder.call(io, 1)).cancels);
    try testing.expect(!f.memory.isReady());
    // The handlers finish into a broken link; new calls are not sent.
    try testing.expectError(error.Closed, f.recorder.respond(io, 0, &.{ .status = .ok }));
    try f.recorder.releaseCall(io, 0, .canceled);
    try testing.expectError(error.Unavailable, f.memory.call(io, &request, optionsOf(&arena)));

    f.memory.restoreLink();
    try testing.expect(f.memory.isReady());
    var third = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (third.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 3);
    try f.recorder.respond(io, 2, &.{ .status = .ok, .body = "back" });
    try f.recorder.releaseCall(io, 2, .completed);
    try testing.expectEqualStrings("back", (try third.await(io)).body);
    // A call from before the break stays cut.
    try testing.expectError(error.Closed, f.recorder.respond(io, 1, &.{ .status = .ok }));
    try f.recorder.releaseCall(io, 1, .canceled);
    try f.expectClean(io);
}

/// An engine that holds a call inside `admit` or `start` until the test
/// opens the gate, so that the link can break or the server close right
/// then.
const Gate = struct {
    hold: enum { admit, start },
    service_value: transport.Dispatcher.Service = .{
        .routes = &.{get_user},
        .max_inflight = 8,
        .max_request_bytes = 64,
        .max_metadata_entries = 64,
        .max_metadata_bytes = 16 * 1024,
    },
    entered: std.Io.Event = .unset,
    open: std.Io.Event = .unset,
    buffer: [64]u8 = undefined,
    len: usize = 0,
    reply: ?Reply = null,
    start_returned: std.atomic.Value(bool) = .init(false),
    cancels: std.atomic.Value(u32) = .init(0),
    cancels_inside_start: std.atomic.Value(u32) = .init(0),
    abandoned: std.atomic.Value(bool) = .init(false),

    const vtable: transport.Dispatcher.VTable = .{ .service = serviceFn, .admit = admitFn, .fail = failFn, .routeStats = routeStatsFn };
    const incoming_vtable: Incoming.VTable = .{ .body = bodyFn, .start = startFn, .abandon = abandonFn, .cancel = cancelFn };

    fn dispatcher(g: *Gate) transport.Dispatcher {
        return .{ .ptr = g, .vtable = &vtable };
    }

    fn serviceFn(ptr: *anyopaque) *const transport.Dispatcher.Service {
        const g: *Gate = @ptrCast(@alignCast(ptr));
        return &g.service_value;
    }

    fn admitFn(ptr: *anyopaque, io: std.Io, head: *const transport.RequestHead, body_len: usize) transport.Dispatcher.Admission {
        _ = head;
        const g: *Gate = @ptrCast(@alignCast(ptr));
        if (g.hold == .admit) g.wait(io);
        g.len = body_len;
        return .{ .accepted = .{ .ptr = g, .vtable = &incoming_vtable } };
    }

    fn failFn(_: *anyopaque, _: std.Io, _: transport.Dispatcher.FatalError, _: ?*const transport.Diagnostics) void {}

    fn routeStatsFn(_: *anyopaque, _: usize) transport.Dispatcher.RouteStats {
        return .{ .requests = 0, .errors = 0, .processing_time = .zero };
    }

    fn bodyFn(ptr: *anyopaque) []u8 {
        const g: *Gate = @ptrCast(@alignCast(ptr));
        return g.buffer[0..g.len];
    }

    fn startFn(ptr: *anyopaque, io: std.Io, reply: Reply) ?model.Failure {
        const g: *Gate = @ptrCast(@alignCast(ptr));
        g.reply = reply;
        if (g.hold == .start) g.wait(io);
        g.start_returned.store(true, .release);
        return null;
    }

    fn abandonFn(ptr: *anyopaque, io: std.Io) void {
        _ = io;
        const g: *Gate = @ptrCast(@alignCast(ptr));
        g.abandoned.store(true, .release);
    }

    fn cancelFn(ptr: *anyopaque, io: std.Io) void {
        _ = io;
        const g: *Gate = @ptrCast(@alignCast(ptr));
        _ = g.cancels.fetchAdd(1, .monotonic);
        if (!g.start_returned.load(.acquire)) _ = g.cancels_inside_start.fetchAdd(1, .monotonic);
    }

    fn wait(g: *Gate, io: std.Io) void {
        g.entered.set(io);
        g.open.waitUncancelable(io);
    }
};

test "breakLink while a call is in start: its cancel comes once start has returned" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .hold = .start };
    try memory.start(io, gate.dispatcher());
    defer memory.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    // Also when a check fails: the call waits at the gate uncancelably.
    defer gate.open.set(io);
    try gate.entered.wait(io);
    memory.breakLink(io);
    try testing.expectEqual(@as(u32, 0), gate.cancels.load(.monotonic));
    gate.open.set(io);
    try testing.expectError(error.ConnectionLost, caller.await(io));
    try testing.expectEqual(@as(u32, 1), gate.cancels.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), gate.cancels_inside_start.load(.monotonic));
    gate.reply.?.release(io, .canceled);
}

test "breakLink while a call is in admit: the call is abandoned and the client gets Unavailable" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .hold = .admit };
    try memory.start(io, gate.dispatcher());
    defer memory.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    // Also when a check fails: the call waits at the gate uncancelably.
    defer gate.open.set(io);
    try gate.entered.wait(io);
    memory.breakLink(io);
    gate.open.set(io);
    try testing.expectError(error.Unavailable, caller.await(io));
    try testing.expect(gate.abandoned.load(.acquire));
    try testing.expectEqual(@as(?Reply, null), gate.reply);
    try testing.expectEqual(@as(u32, 0), gate.cancels.load(.monotonic));
}

/// One of many clients: waits a random moment, then calls with its own
/// body.
fn callAfterPause(client: ClientTransport, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions, pause: std.Io.Duration) ClientTransport.CallError!model.Response {
    try io.sleep(pause, .awake);
    return client.call(io, request, options);
}

test "64 calls at once with random delays: each gets its own response, and the journal is clean" {
    const io = testing.io;
    const n = 64;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var prng: std.Random.DefaultPrng = .init(64);
    const random = prng.random();

    var bodies: [n][7]u8 = undefined;
    var requests: [n]transport.Request = undefined;
    var arenas: [n]std.heap.ArenaAllocator = undefined;
    var callers: [n]std.Io.Future(ClientTransport.CallError!model.Response) = undefined;
    var started: usize = 0;
    defer for (callers[0..started], arenas[0..started]) |*caller, *arena| {
        if (caller.cancel(io)) |_| {} else |_| {}
        arena.deinit();
    };
    for (0..n) |i| {
        _ = std.fmt.bufPrint(&bodies[i], "call-{d:0>2}", .{i}) catch unreachable;
        requests[i] = requestOf(io, &bodies[i], .fromSeconds(30));
        arenas[i] = .init(testing.allocator);
        const pause: std.Io.Duration = .fromMicroseconds(random.intRangeAtMost(i64, 0, 3000));
        callers[i] = try io.concurrent(callAfterPause, .{ f.memory.clientTransport(), io, &requests[i], optionsOf(&arenas[i]), pause });
        started += 1;
    }
    try f.recorder.waitStarted(io, n);

    // The server answers in random order, with pauses: each call gets the
    // body it sent.
    var order: [n]usize = undefined;
    for (&order, 0..) |*index, i| index.* = i;
    random.shuffle(usize, &order);
    for (order) |index| {
        try f.recorder.respond(io, index, &.{ .status = .ok, .body = (try f.recorder.call(io, index)).body.? });
        try f.recorder.releaseCall(io, index, .completed);
        if (random.boolean()) try io.sleep(.fromMicroseconds(random.intRangeAtMost(i64, 0, 500)), .awake);
    }
    for (&callers, &bodies) |*caller, *body| {
        try testing.expectEqualStrings(body, (try caller.await(io)).body);
    }

    try f.expectClean(io);
    var counts: std.EnumArray(std.meta.Tag(RecordingDispatcher.Event.Kind), usize) = .initFill(0);
    for (f.recorder.events()) |event| counts.getPtr(std.meta.activeTag(event.kind)).* += 1;
    for ([_]std.meta.Tag(RecordingDispatcher.Event.Kind){ .admit, .start, .send, .release }) |kind| {
        try testing.expectEqual(@as(usize, n), counts.get(kind));
    }
    try testing.expectEqual(@as(usize, 0), counts.get(.cancel) + counts.get(.abandon));
}

test "a call without a deadline sends no budget and waits for its response" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var request = requestOf(io, "{}", .fromSeconds(5));
    request.ctx = core.Context.root;
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try testing.expectEqual(@as(?std.Io.Duration, null), (try f.recorder.call(io, 0)).head.timeout);
    try f.recorder.respond(io, 0, &.{ .status = .ok, .body = "late but fine" });
    try f.recorder.releaseCall(io, 0, .completed);
    try testing.expectEqualStrings("late but fine", (try caller.await(io)).body);
    try f.expectClean(io);
}

/// Waits to be canceled, keeps the cancelation, then calls the functions
/// that have no `error.Canceled` to return: the next cancelation point must
/// still see it.
fn keepsCancelation(f: *Fixture, io: std.Io) !void {
    var never: std.Io.Event = .unset;
    never.wait(io) catch |err| switch (err) {
        error.Canceled => io.recancel(),
    };
    try f.recorder.releaseCall(io, 0, .canceled);
    f.memory.breakLink(io);
    f.memory.restoreLink();
    f.memory.drain(io);
    f.memory.close(io);
    return io.checkCancel();
}

test "release, breakLink, drain and close keep a cancelation of the calling task" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    var task = try io.concurrent(keepsCancelation, .{ &f, io });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expectError(error.ConnectionLost, caller.await(io));
    try f.expectClean(io);
}

/// Waits to be canceled, then makes calls that would fail for other reasons
/// too, each with the cancelation pending on entry.
fn callsWhileCanceled(memory: *MemoryTransport, io: std.Io, requests: []const transport.Request, arena: *std.heap.ArenaAllocator) !void {
    var never: std.Io.Event = .unset;
    never.wait(io) catch |err| switch (err) {
        error.Canceled => {},
    };
    for (requests) |*request| {
        io.recancel();
        if (memory.call(io, request, optionsOf(arena))) |_| {
            return error.TestUnexpectedResult;
        } else |err| if (err != error.Canceled) return err;
    }
    io.recancel();
    return io.checkCancel();
}

test "a cancelation pending on entry gives Canceled before any other error" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{ .max_body_bytes = 1 });
    defer memory.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // No server, an injected error, a body over max_body_bytes, a deadline
    // that has passed.
    memory.failNext(error.Unexpected);
    const requests = [_]transport.Request{
        requestOf(io, "", .fromSeconds(5)),
        requestOf(io, "{}", .fromSeconds(5)),
        requestOf(io, "", .zero),
    };
    var task = try io.concurrent(callsWhileCanceled, .{ &memory, io, &requests, &arena });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, task.cancel(io));
}

test "a second close waits for the calls the first one waits for" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .hold = .admit };
    try memory.start(io, gate.dispatcher());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    defer gate.open.set(io);
    try gate.entered.wait(io);
    var first = try io.concurrent(closeAndCheck, .{ &memory, io, &gate });
    defer _ = first.cancel(io);
    var second = try io.concurrent(closeAndCheck, .{ &memory, io, &gate });
    defer _ = second.cancel(io);
    defer gate.open.set(io);
    try io.sleep(.fromMilliseconds(20), .awake);
    gate.open.set(io);
    try testing.expect(first.await(io));
    try testing.expect(second.await(io));
    try testing.expectError(error.Unavailable, caller.await(io));
}

test "a call its client gave up on and then cut by breakLink is canceled once" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromMilliseconds(300));
    var caller = try io.concurrent(callTask, .{ f.memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    try f.recorder.waitStarted(io, 1);
    try testing.expectError(error.Timeout, caller.await(io));
    f.memory.breakLink(io);
    try testing.expectEqual(@as(u32, 1), (try f.recorder.call(io, 0)).cancels);
    try f.recorder.releaseCall(io, 0, .canceled);
    f.memory.restoreLink();
    try f.expectClean(io);
}

test "failServer tells the running server that the transport broke; after close it does nothing" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(io, .{}, .{ .routes = &.{get_user} });
    defer f.deinit(io);

    f.memory.failServer(io, error.AccessDenied);
    const fatal = f.recorder.fatal(io).?;
    try testing.expectEqual(error.AccessDenied, fatal.err);
    try testing.expectEqualStrings("failure injected with failServer", fatal.diagnostics.?.message());
    try testing.expectEqual(error.AccessDenied, fatal.diagnostics.?.cause.?);

    f.recorder.close(io);
    f.memory.failServer(io, error.Unexpected);
    try testing.expectEqual(error.AccessDenied, f.recorder.fatal(io).?.err);
    try f.expectClean(io);
}

fn closeAndCheck(memory: *MemoryTransport, io: std.Io, gate: *const Gate) bool {
    memory.close(io);
    return gate.abandoned.load(.acquire);
}

test "close waits for a call in admit, which is abandoned before close returns" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .hold = .admit };
    try memory.start(io, gate.dispatcher());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = requestOf(io, "{}", .fromSeconds(30));
    var caller = try io.concurrent(callTask, .{ memory.clientTransport(), io, &request, optionsOf(&arena) });
    defer if (caller.cancel(io)) |_| {} else |_| {};
    // Also when a check fails: the call waits at the gate uncancelably.
    defer gate.open.set(io);
    try gate.entered.wait(io);
    var closer = try io.concurrent(closeAndCheck, .{ &memory, io, &gate });
    defer _ = closer.cancel(io);
    defer gate.open.set(io);
    try io.sleep(.fromMilliseconds(20), .awake);
    gate.open.set(io);
    // When close returned, the call had been abandoned.
    try testing.expect(closer.await(io));
    try testing.expectError(error.Unavailable, caller.await(io));
}
