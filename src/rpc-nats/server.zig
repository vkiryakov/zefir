//! The server side of the NATS transport: a subscription per route in the
//! queue group, a task per subscription that hands its requests to the
//! engine, and the `Reply` of every call, which publishes the response to
//! the reply subject of the request.
//!
//! A receiving task waits only in `Conn.next`, and before its first one
//! until `start` has started every task: everything it does with a
//! request runs with cancelation blocked, so `close` stops it there and
//! never in the middle of a call. It does no I/O between `admit` and
//! `start` but the copy of the body: a request is admitted, filled and
//! started, or refused, before the task takes the next one.

const std = @import("std");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const shared = @import("shared.zig");
const subject = @import("subject.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.rpc_nats);

const Failure = rpc.Failure;
const Reply = rpc.transport.Reply;

/// The server side's part of `Transport`.
pub const State = struct {
    /// Serializes `start`, `drain` and `close`.
    lifecycle: std.Io.Mutex = .init,
    /// Written under `lifecycle`; the receiving tasks and `Reply.send`
    /// read it without.
    phase: std.atomic.Value(Phase) = .init(.idle),
    /// Set by `start`, before the receiving tasks.
    dispatcher: rpc.transport.Dispatcher = undefined,
    routes: []Route = &.{},
    /// The receiving tasks; `close` alone awaits and cancels them.
    group: std.Io.Group = .init,
    /// Set once `start` has started every receiving task; they take no
    /// request before, so a start that fails leaves no call behind.
    started: std.Io.Event = .unset,
    /// Calls whose `Reply` the engine holds.
    live_calls: std.atomic.Value(usize) = .init(0),
};

pub const Phase = enum(u8) {
    idle,
    running,
    draining,
    /// `close` runs: a receiving task abandons and refuses what it holds.
    closing,
    /// A late `Reply.send` gets `error.Closed`.
    closed,
};

/// One route: its subscription and the room for the metadata of its
/// requests.
const Route = struct {
    transport: *Transport,
    route: rpc.Route,
    subject_buffer: [subject.max_subject_bytes]u8,
    subject_len: u8,
    sub: Conn.Sub,
    scratch: wire.Scratch,

    fn subjectOf(r: *const Route) []const u8 {
        return r.subject_buffer[0..r.subject_len];
    }
};

/// The pause after `next` failed with Disconnected or OutOfMemory, so that
/// a library that keeps failing at once does not spin the task.
const retry_pause: std.Io.Duration = .fromMilliseconds(20);

/// The refusal for a request that comes while the server side closes.
const stopping: Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" };
/// The refusal for an admitted request with no memory for its call.
const out_of_memory: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Out of memory" };

pub fn start(t: *Transport, io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void {
    const s = &t.server;
    s.lifecycle.lockUncancelable(io);
    defer s.lifecycle.unlock(io);
    const before = s.phase.load(.acquire);
    switch (before) {
        .idle, .closed => {},
        .running, .draining, .closing => return error.AddressInUse,
    }
    shared.checkIo(t, io);
    const routes = try makeRoutes(t, io, dispatcher.service());
    errdefer freeRoutes(t, io, routes);
    var subscribed: usize = 0;
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        for (routes[0..subscribed]) |*r| t.conn.unsubscribe(io, r.sub);
    }
    const timeout = shared.timeoutAfter(io, t.options.flush_timeout);
    for (routes) |*r| {
        r.sub = t.conn.subscribe(io, r.subjectOf(), t.options.queue_group, timeout) catch |err| return startError(r, err);
        subscribed += 1;
    }
    // The broker confirms the subscriptions and their permissions here;
    // without it, a denied subject would show only as no responders.
    t.conn.flush(io, timeout) catch |err| return startError(null, err);
    s.dispatcher = dispatcher;
    s.routes = routes;
    // No task waits on it: the group is empty.
    s.started.reset();
    s.phase.store(.running, .release);
    for (routes) |*r| {
        s.group.concurrent(io, receive, .{ r, io }) catch |err| {
            s.phase.store(.closing, .release);
            s.group.cancel(io);
            s.phase.store(before, .release);
            s.routes = &.{};
            return err;
        };
    }
    s.started.set(io);
}

fn startError(route: ?*const Route, err: Conn.Error) rpc.ServerTransport.StartError {
    const what = if (route) |r| r.subjectOf() else "the flush";
    return switch (err) {
        error.PermissionDenied => {
            log.warn("the NATS permissions deny the server {s}", .{if (route) |r| r.subjectOf() else "one of its subjects"});
            return error.AccessDenied;
        },
        error.Disconnected, error.ConnectionClosed, error.Timeout => error.Unavailable,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSubject, error.PayloadTooLarge, error.SlowConsumer => {
            log.warn("the NATS connection refused {s}: {t}", .{ what, err });
            return error.Unexpected;
        },
    };
}

/// The routes of `service` with their subjects and their room for metadata.
fn makeRoutes(t: *Transport, io: std.Io, service: *const rpc.transport.Dispatcher.Service) rpc.ServerTransport.StartError![]Route {
    // A Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const routes = try t.gpa.alloc(Route, service.routes.len);
    var made: usize = 0;
    errdefer {
        for (routes[0..made]) |*r| freeScratch(t, r.scratch);
        t.gpa.free(routes);
    }
    for (service.routes, routes) |route, *r| {
        r.* = .{ .transport = t, .route = route, .subject_buffer = undefined, .subject_len = 0, .sub = undefined, .scratch = undefined };
        const name = subject.routeSubject(&r.subject_buffer, t.options.subject_prefix, route) orelse {
            log.warn("the route {s}.v{d}.{s} has no NATS subject", .{ route.service, route.version, route.method });
            return error.InvalidConfiguration;
        };
        r.subject_len = @intCast(name.len);
        const entries = try t.gpa.alloc(rpc.Metadata.Entry, @as(usize, service.max_metadata_entries) + 1);
        errdefer t.gpa.free(entries);
        r.scratch = .{ .entries = entries, .keys = try t.gpa.alloc(u8, service.max_metadata_bytes) };
        made += 1;
    }
    return routes;
}

fn freeRoutes(t: *Transport, io: std.Io, routes: []Route) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    for (routes) |*r| freeScratch(t, r.scratch);
    t.gpa.free(routes);
}

fn freeScratch(t: *Transport, scratch: wire.Scratch) void {
    t.gpa.free(scratch.keys);
    t.gpa.free(scratch.entries);
}

pub fn drain(t: *Transport, io: std.Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const s = &t.server;
    s.lifecycle.lockUncancelable(io);
    defer s.lifecycle.unlock(io);
    if (s.phase.load(.acquire) != .running) return;
    s.phase.store(.draining, .release);
    drainRoutes(t, io);
}

/// What is on its way still comes out of `next`, then null.
fn drainRoutes(t: *Transport, io: std.Io) void {
    for (t.server.routes) |*r| {
        t.conn.drain(io, r.sub) catch |err| log.debug("the drain of {s} failed: {t}", .{ r.subjectOf(), err });
    }
}

pub fn close(t: *Transport, io: std.Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const s = &t.server;
    s.lifecycle.lockUncancelable(io);
    defer s.lifecycle.unlock(io);
    const before = s.phase.load(.acquire);
    switch (before) {
        .idle, .closed => return,
        .running, .draining => {},
        // Under `lifecycle`, a close finishes before another looks.
        .closing => unreachable,
    }
    // Before the drain: a receiving task that gets null from it must not
    // take it for a subscription that ended while the server runs.
    s.phase.store(.closing, .release);
    if (before == .running) drainRoutes(t, io);
    // A task in `next` gets the cancelation at once; one with a request
    // hands it over or refuses it first.
    s.group.cancel(io);
    // The responses published so far reach the server.
    t.conn.flush(io, shared.timeoutAfter(io, t.options.flush_timeout)) catch |err| log.debug("the flush of close failed: {t}", .{err});
    for (s.routes) |*r| t.conn.unsubscribe(io, r.sub);
    freeRoutes(t, io, s.routes);
    s.routes = &.{};
    s.phase.store(.closed, .release);
}

/// The receiving task of one route.
fn receive(r: *Route, io: std.Io) void {
    const t = r.transport;
    // A start that fails cancels the task here.
    t.server.started.wait(io) catch return;
    while (true) {
        const message = t.conn.next(io, r.sub, .none) catch |err| switch (err) {
            error.Canceled => return,
            error.Timeout => continue,
            // The library reconnects; `isReady` is false meanwhile.
            error.Disconnected, error.OutOfMemory => {
                io.sleep(retry_pause, .awake) catch return;
                continue;
            },
            error.SlowConsumer => {
                shared.count(t, .slow_consumer_errors);
                log.warn("the subscription to {s} lost requests as a slow consumer; its pending limits must hold the server's max_inflight", .{r.subjectOf()});
                continue;
            },
            error.PermissionDenied => return fail(t, io, r, error.AccessDenied, err),
            error.ConnectionClosed, error.InvalidSubject, error.PayloadTooLarge => return fail(t, io, r, if (err == error.ConnectionClosed) error.Unavailable else error.Unexpected, err),
        } orelse {
            // Drained, or ended by someone else while the server runs.
            if (t.server.phase.load(.acquire) == .running) fail(t, io, r, error.Unavailable, null);
            return;
        };
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        handle(t, io, r, message);
    }
}

/// The whole transport broke: the engine stops the server.
fn fail(t: *Transport, io: std.Io, r: *const Route, err: rpc.transport.Dispatcher.FatalError, cause: ?anyerror) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var diagnostics: rpc.transport.Diagnostics = .{};
    if (cause) |c| {
        diagnostics.set(.receive, c, "the subscription to {s} failed: {t}", .{ r.subjectOf(), c });
    } else {
        diagnostics.set(.receive, null, "the subscription to {s} ended while the server runs", .{r.subjectOf()});
    }
    t.server.dispatcher.fail(io, err, &diagnostics);
}

/// One request: to the engine, or refused.
fn handle(t: *Transport, io: std.Io, r: *Route, message: Conn.InMsg) void {
    // After the copies: the head is borrowed for `admit`, the body copied.
    defer message.release();
    const received_at = std.Io.Clock.awake.now(io);
    const reply_to = message.reply_to orelse {
        shared.count(t, .requests_without_reply_to);
        return;
    };
    if (!subject.isAllowedReplyTo(reply_to, t.reply_prefixes)) {
        shared.count(t, .requests_with_foreign_reply_to);
        return;
    }
    if (closing(t)) return refuse(t, io, reply_to, stopping);
    const fields = switch (wire.parseRequest(message.header_block, r.scratch)) {
        .request => |parsed| parsed,
        .refused => |failure| return refuse(t, io, reply_to, failure),
    };
    const request_id = fields.request_id orelse id: {
        var id: [16]u8 = undefined;
        io.random(&id);
        break :id id;
    };
    const head: rpc.transport.RequestHead = .{
        .route = r.route,
        .request_id = request_id,
        .codec = fields.codec,
        .timeout = fields.timeout,
        .received_at = received_at,
        .metadata = fields.metadata,
    };
    const incoming = switch (t.server.dispatcher.admit(io, &head, message.payload.len)) {
        .accepted => |incoming| incoming,
        .rejected => |failure| return refuse(t, io, reply_to, failure),
    };
    // `close` began while the engine decided: the call will not start.
    if (closing(t)) {
        incoming.abandon(io);
        return refuse(t, io, reply_to, stopping);
    }
    const call = Call.create(t, reply_to) catch {
        incoming.abandon(io);
        return refuse(t, io, reply_to, out_of_memory);
    };
    @memcpy(incoming.body(), message.payload);
    // The handler may answer and release the call before `start` returns:
    // `call` is not touched after a null.
    if (incoming.start(io, .init(call))) |failure| {
        call.destroy();
        refuse(t, io, reply_to, failure);
    }
}

fn closing(t: *const Transport) bool {
    return switch (t.server.phase.load(.acquire)) {
        .closing, .closed => true,
        .idle, .running, .draining => false,
    };
}

/// Answers a call that did not run, as refused.
fn refuse(t: *Transport, io: std.Io, reply_to: []const u8, failure: Failure) void {
    const response: rpc.Response = .{ .status = .{ .failure = failure }, .refused = true };
    publishResponse(t, io, reply_to, &response) catch |err| log.debug("a refusal was not published: {t}", .{err});
}

/// Publishes `response` to `reply_to`, waiting for room no longer than
/// `publish_timeout`.
fn publishResponse(t: *Transport, io: std.Io, reply_to: []const u8, response: *const rpc.Response) Conn.Error!void {
    var stack: [2048]u8 = undefined;
    var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, t.gpa);
    const a = buffer_first.allocator();
    const headers = headers: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :headers try wire.responseHeaders(a, response);
    };
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        headers.deinit(a);
    }
    try t.conn.publish(io, .{ .subject = reply_to, .headers = headers.headers, .payload = response.body }, shared.timeoutAfter(io, t.options.publish_timeout));
}

/// A call the engine runs: its `Reply`.
const Call = struct {
    transport: *Transport,
    reply_to: []u8,

    fn create(t: *Transport, reply_to: []const u8) error{OutOfMemory}!*Call {
        const c = try t.gpa.create(Call);
        errdefer t.gpa.destroy(c);
        c.* = .{ .transport = t, .reply_to = try t.gpa.dupe(u8, reply_to) };
        _ = t.server.live_calls.fetchAdd(1, .monotonic);
        return c;
    }

    fn destroy(c: *Call) void {
        const t = c.transport;
        t.gpa.free(c.reply_to);
        t.gpa.destroy(c);
        _ = t.server.live_calls.fetchSub(1, .release);
    }

    /// Publishes the response to the reply subject of the request.
    pub fn send(c: *Call, io: std.Io, response: *const rpc.Response) Reply.SendError!void {
        const t = c.transport;
        if (t.server.phase.load(.acquire) == .closed) return error.Closed;
        publishResponse(t, io, c.reply_to, response) catch |err| return switch (err) {
            error.PayloadTooLarge => error.ResponseTooLarge,
            error.Disconnected, error.ConnectionClosed => error.Closed,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSubject, error.PermissionDenied, error.SlowConsumer, error.Timeout => {
                log.debug("a response was not published: {t}", .{err});
                return error.Unexpected;
            },
        };
    }

    /// Forgets the call; NATS has nothing to acknowledge.
    pub fn release(c: *Call, io: std.Io, disposition: Reply.Disposition) void {
        _ = disposition;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        c.destroy();
    }
};
