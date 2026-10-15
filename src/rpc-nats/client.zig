//! The client side of the NATS transport. All calls share one inbox,
//! `<inbox_prefix>.<random token>`: one subscription to `<inbox>.*`, read
//! by a task of the transport, and the reply subject of a call is
//! `<inbox>.<call number>`. A call waits for its response in
//! `rpc.transport.Pending` under its number, so timeouts, cancelation, no
//! responders and late responses behave the same with every NATS library.
//!
//! The inbox starts with the first call: its subscription is confirmed with
//! a flush, so an inbox that NATS permissions deny fails that call with
//! AccessDenied instead of timeouts. Calls that come meanwhile wait for
//! the start no longer than their own deadlines. A start that fails leaves
//! nothing behind, and the next call tries again. Once the connection
//! closes for good, the calls that wait get ConnectionLost.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const shared = @import("shared.zig");
const subject = @import("subject.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.rpc_nats);

const CallError = rpc.ClientTransport.CallError;
const CallOptions = rpc.ClientTransport.CallOptions;
const Diagnostics = rpc.transport.Diagnostics;
const Pending = rpc.transport.Pending;

/// The client side's part of `Transport`.
pub const State = struct {
    /// Guards the changes of `phase` and `live`; never held across I/O.
    mutex: std.Io.Mutex = .init,
    /// Changed under `mutex`; calls read it without.
    phase: std.atomic.Value(Phase) = .init(.idle),
    /// The subscription and the task of the inbox while the phase is
    /// `running` or `broken`; null while it is `idle` or `starting`. The
    /// call that moves the phase from `broken` to `starting`, and `deinit`,
    /// take them out under `mutex` and end them, so each is ended once.
    live: ?Handles = null,
    /// `<inbox_prefix>.<token>`, written once, by the first start, before
    /// the phase is first `running`; a restarted inbox keeps its name.
    inbox_buffer: [subject.max_subject_bytes]u8 = undefined,
    inbox_len: u8 = 0,

    fn inbox(s: *const State) []const u8 {
        return s.inbox_buffer[0..s.inbox_len];
    }
};

pub const Phase = enum(u8) {
    idle,
    /// A call subscribes; other calls wait.
    starting,
    running,
    /// The subscription ended or failed for good: its task has returned or
    /// is returning, and the next call starts the inbox again.
    broken,
};

/// The pause after `next` failed with Disconnected or OutOfMemory.
const retry_pause: std.Io.Duration = .fromMilliseconds(20);

/// A response as the inbox task received it, waiting for its call.
const Received = struct {
    gpa: std.mem.Allocator,
    msg: Conn.InMsg,

    fn free(context: *anyopaque) void {
        const r: *Received = @ptrCast(@alignCast(context));
        r.msg.release();
        r.gpa.destroy(r);
    }
};

pub fn call(t: *Transport, io: std.Io, request: *const rpc.transport.Request, options: CallOptions) CallError!rpc.Response {
    // A cancelation pending on entry comes before any other error.
    try io.checkCancel();
    shared.checkIo(t, io);
    const diagnostics = options.diagnostics;
    if (!t.conn.isConnected()) {
        note(diagnostics, .connect, null, "no link to the NATS server", .{});
        return error.Unavailable;
    }
    var subject_buffer: [subject.max_subject_bytes]u8 = undefined;
    const route_subject = subject.routeSubject(&subject_buffer, t.options.subject_prefix, request.route) orelse {
        note(diagnostics, .send, null, "the route {s}.v{d}.{s} has no NATS subject", .{ request.route.service, request.route.version, request.route.method });
        return error.Unexpected;
    };
    const deadline = request.ctx.deadline orelse core.Deadline.after(now(io), .max);
    if (deadline.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return error.Timeout;

    try startInbox(t, io, deadline, diagnostics);
    const slot = t.pending.acquire(io) catch |err| {
        note(diagnostics, .send, err, "{d} calls wait for their responses already", .{t.options.max_pending});
        return err;
    };
    defer releaseSlot(t, io, slot);
    // `failAll` reaches only the calls that wait already: an inbox that
    // ended since `startInbox` returned shows here.
    if (t.client.phase.load(.acquire) != .running) {
        note(diagnostics, .send, null, "the inbox of the client ended", .{});
        return error.Unavailable;
    }
    var reply_buffer: [subject.max_subject_bytes]u8 = undefined;
    const reply_to = subject.replySubject(&reply_buffer, t.client.inbox(), slot.id);

    var stack: [16]Conn.Header = undefined;
    const count = wire.requestHeaderCount(request.metadata.len);
    const buffer = if (count <= stack.len) stack[0..count] else heap: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :heap try options.allocator.alloc(Conn.Header, count);
    };
    defer if (count > stack.len) {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        options.allocator.free(buffer);
    };
    var text: wire.RequestText = .{};
    // The budget left, right before publish.
    const left = deadline.remaining(now(io));
    if (left.nanoseconds < std.time.ns_per_ms) return error.Timeout;
    const ms: u64 = @intCast(@min(@divFloor(left.nanoseconds, std.time.ns_per_ms), std.math.maxInt(u64)));
    const headers = wire.requestHeaders(buffer, &text, request.request_id, request.codec, ms, request.metadata) orelse {
        note(diagnostics, .send, null, "the codec \"{s}\" cannot be a media type application/<codec>", .{request.codec});
        return error.UnsupportedProtocol;
    };
    t.conn.publish(io, .{ .subject = route_subject, .reply_to = reply_to, .headers = headers, .payload = request.body }, deadline.toTimeout()) catch |err| {
        note(diagnostics, .send, err, "the publish to {s} failed", .{route_subject});
        return switch (err) {
            error.PayloadTooLarge => error.RequestTooLarge,
            error.PermissionDenied => error.AccessDenied,
            error.Disconnected, error.ConnectionClosed => error.Unavailable,
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSubject, error.SlowConsumer => error.Unexpected,
        };
    };

    const delivery = t.pending.wait(io, slot, deadline) catch |err| {
        if (err == error.ConnectionLost) note(diagnostics, .wait, null, "the NATS connection closed for good", .{});
        return err;
    };
    defer freeDelivery(io, delivery);
    const received: *Received = @ptrCast(@alignCast(delivery.context));
    // The caller's allocator; a Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return wire.parseResponse(options.allocator, received.msg.header_block, received.msg.payload, .{
        .max_body_bytes = options.max_response_bytes,
        .max_metadata_entries = options.max_response_metadata_entries,
        .max_metadata_bytes = options.max_response_metadata_bytes,
    }, diagnostics);
}

/// How often a call that waits for another call to start the inbox looks
/// again.
const start_poll: std.Io.Duration = .fromMilliseconds(1);

/// The subscription and the task of an inbox.
const Handles = struct { sub: Conn.Sub, task: std.Io.Future(void) };

/// Starts the inbox, unless it runs: a subscription to `<inbox>.*`
/// confirmed by a flush, and its task, on the `io` of this call. While
/// another call starts it, waits no longer than `deadline`.
fn startInbox(t: *Transport, io: std.Io, deadline: core.Deadline, diagnostics: ?*Diagnostics) CallError!void {
    const s = &t.client;
    while (s.phase.load(.acquire) != .running) {
        var old: ?Handles = null;
        const mine = mine: {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            switch (s.phase.load(.acquire)) {
                .running => return,
                .starting => break :mine false,
                .idle => {},
                .broken => {
                    old = s.live;
                    s.live = null;
                },
            }
            s.phase.store(.starting, .release);
            break :mine true;
        };
        if (mine) return startAs(t, io, deadline, diagnostics, old);
        // Another call starts it.
        if (deadline.isExpired(now(io))) return error.Timeout;
        try io.sleep(start_poll, .awake);
    }
}

/// The start, by the one call that moved the phase to `starting`; after an
/// error the phase is `idle` again. `old` is a broken inbox to end first.
fn startAs(t: *Transport, io: std.Io, deadline: core.Deadline, diagnostics: ?*Diagnostics, old: ?Handles) CallError!void {
    const s = &t.client;
    errdefer setPhase(t, io, .idle);
    if (old) |o| end(t, io, o);
    if (s.inbox_len == 0) {
        var token: [subject.token_len]u8 = undefined;
        subject.randomToken(io, &token) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.EntropyUnavailable => {
                note(diagnostics, .connect, err, "no entropy for the token of the inbox", .{});
                return error.Unavailable;
            },
        };
        const inbox = std.fmt.bufPrint(&s.inbox_buffer, "{s}.{s}", .{ t.options.inbox_prefix, &token }) catch unreachable;
        s.inbox_len = @intCast(inbox.len);
    }
    var pattern_buffer: [subject.max_subject_bytes]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, "{s}.*", .{s.inbox()}) catch unreachable;
    const sub = try subscribeInbox(t, io, pattern, deadline, diagnostics);
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        t.conn.unsubscribe(io, sub);
    }
    // Held from the start of the task until its handles are in place, which
    // is no I/O: a task that ends at once waits for it in `broken`, so the
    // inbox turns broken only with the handles of this task to end.
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    // A task of the transport: canceling this call does not stop it.
    const task = io.concurrent(readInbox, .{ t, io, sub }) catch |err| {
        note(diagnostics, .connect, err, "no task for the inbox", .{});
        return error.Unavailable;
    };
    s.live = .{ .sub = sub, .task = task };
    s.phase.store(.running, .release);
}

/// The subscription of the inbox to `pattern`, confirmed by a flush. Not
/// while the server side's `start` or `close` waits for its flush: that
/// flush would answer for this subscription.
fn subscribeInbox(t: *Transport, io: std.Io, pattern: []const u8, deadline: core.Deadline, diagnostics: ?*Diagnostics) CallError!Conn.Sub {
    shared.lockConfirming(t, io, deadline) catch |err| {
        note(diagnostics, .connect, err, "the inbox waited for the flush of the server side", .{});
        return err;
    };
    defer t.confirming.unlock(io);
    const sub = t.conn.subscribe(io, pattern, null, deadline.toTimeout()) catch |err| return inboxError(diagnostics, err);
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        t.conn.unsubscribe(io, sub);
    }
    // The broker confirms the subscription and its permissions here.
    t.conn.flush(io, deadline.toTimeout()) catch |err| return inboxError(diagnostics, err);
    return sub;
}

fn setPhase(t: *Transport, io: std.Io, phase: Phase) void {
    t.client.mutex.lockUncancelable(io);
    defer t.client.mutex.unlock(io);
    t.client.phase.store(phase, .release);
}

/// Ends the task of an inbox, which waits in `next` or has returned, and
/// then its subscription; the caller has taken them out of `State.live`.
fn end(t: *Transport, io: std.Io, handles: Handles) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var task = handles.task;
    task.cancel(io);
    t.conn.unsubscribe(io, handles.sub);
}

fn inboxError(diagnostics: ?*Diagnostics, err: Conn.Error) CallError {
    note(diagnostics, .connect, err, "the inbox subscription failed", .{});
    return switch (err) {
        error.PermissionDenied => error.AccessDenied,
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.Disconnected, error.ConnectionClosed, error.InvalidSubject, error.PayloadTooLarge, error.SlowConsumer => error.Unavailable,
    };
}

/// Stops the inbox, for the transport's `deinit`, when no call runs.
pub fn stop(t: *Transport, io: std.Io) void {
    const s = &t.client;
    const old: ?Handles = old: {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        switch (s.phase.load(.acquire)) {
            .idle => break :old null,
            .starting => @panic("rpc_nats.Transport: deinit while a call starts the inbox; let every call return first"),
            .running, .broken => {},
        }
        s.phase.store(.idle, .release);
        const live = s.live;
        s.live = null;
        break :old live;
    };
    if (old) |o| end(t, io, o);
}

/// The inbox task: hands every response to the call of its number.
fn readInbox(t: *Transport, io: std.Io, sub: Conn.Sub) void {
    while (true) {
        const message = t.conn.next(io, sub, .none) catch |err| switch (err) {
            error.Canceled => return,
            error.Timeout => continue,
            // While the library reconnects, a response may still come: the
            // calls wait until their deadlines.
            error.Disconnected, error.OutOfMemory => {
                io.sleep(retry_pause, .awake) catch return;
                continue;
            },
            error.SlowConsumer => {
                shared.count(t, .slow_consumer_errors);
                log.warn("the inbox of the client lost responses as a slow consumer", .{});
                continue;
            },
            error.ConnectionClosed, error.PermissionDenied, error.InvalidSubject, error.PayloadTooLarge => return broken(t, io, err),
        } orelse return broken(t, io, null);
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        deliver(t, io, message);
    }
}

/// The inbox is over: the calls that wait get ConnectionLost, a new call
/// starts another inbox.
fn broken(t: *Transport, io: std.Io, cause: ?anyerror) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (cause) |err| {
        if (err == error.ConnectionClosed) log.debug("the inbox of the client ended: the connection closed", .{}) else log.warn("the inbox of the client ended: {t}", .{err});
    } else log.debug("the inbox subscription of the client ended", .{});
    // Before `failAll`: a call that takes its slot later sees it.
    setPhase(t, io, .broken);
    t.pending.failAll(io, error.ConnectionLost);
}

fn deliver(t: *Transport, io: std.Io, message: Conn.InMsg) void {
    const id = subject.replyId(message.subject) orelse {
        message.release();
        shared.count(t, .late_responses);
        return;
    };
    const received = t.gpa.create(Received) catch {
        // The call ends at its deadline.
        log.debug("no memory for a response; it is dropped", .{});
        message.release();
        return;
    };
    received.* = .{ .gpa = t.gpa, .msg = message };
    const delivery: Pending.Delivery = .{ .response = .{ .status = .ok, .body = message.payload }, .context = received, .release = Received.free };
    if (!t.pending.complete(io, id, delivery)) {
        // Late: the call returned with Timeout or Canceled.
        Received.free(received);
        shared.count(t, .late_responses);
    }
}

fn releaseSlot(t: *Transport, io: std.Io, slot: Pending.Slot) void {
    // It may free a response that came too late.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    t.pending.release(io, slot);
}

fn freeDelivery(io: std.Io, delivery: Pending.Delivery) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    delivery.release(delivery.context);
}

fn note(diagnostics: ?*Diagnostics, phase: Diagnostics.Phase, cause: ?anyerror, comptime fmt: []const u8, args: anytype) void {
    if (diagnostics) |d| d.set(phase, cause, fmt, args);
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}
