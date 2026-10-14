//! Tests of `rpc.RawServer` through transports: the memory transport end
//! to end, and a test transport that records every `Reply` call of the
//! engine.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const failures = @import("../failures.zig");
const waiting = @import("../wait.zig");
const RawServer = @import("RawServer.zig");
const Context = @import("Context.zig").Context;
const ServerTransport = @import("../ServerTransport.zig");
const ClientTransport = @import("../ClientTransport.zig");
const MemoryTransport = @import("../testing/MemoryTransport.zig");

const testing = std.testing;
const Reply = transport.Reply;
const Incoming = transport.Incoming;

/// A handler on bytes from a pointer to a type with
/// `handle(self, ctx, request)`.
fn handlerOf(impl: anytype) RawServer.Handler {
    const T = @typeInfo(@TypeOf(impl)).pointer.child;
    return .{ .ptr = impl, .handle = struct {
        fn handle(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.handle(ctx, request);
        }
    }.handle };
}

const Echo = struct {
    fn handle(_: *Echo, _: *Context, request: []const u8) anyerror![]const u8 {
        return request;
    }
};

/// Sleeps, a cancelation point, then answers "slept".
const Sleeper = struct {
    io: std.Io,
    duration: std.Io.Duration,
    started: std.atomic.Value(u32) = .init(0),
    ended: std.atomic.Value(u32) = .init(0),

    fn handle(s: *Sleeper, _: *Context, _: []const u8) anyerror![]const u8 {
        _ = s.started.fetchAdd(1, .acq_rel);
        defer _ = s.ended.fetchAdd(1, .acq_rel);
        try s.io.sleep(s.duration, .awake);
        return "slept";
    }

    fn waitStarted(s: *Sleeper, io: std.Io, n: u32) !void {
        try waitFor(io, &s.started, n);
    }
};

/// Waits until `open` is set, then echoes; canceling the call ends the
/// wait.
const Gate = struct {
    io: std.Io,
    open: std.Io.Event = .unset,
    entered: std.atomic.Value(u32) = .init(0),

    fn handle(g: *Gate, _: *Context, request: []const u8) anyerror![]const u8 {
        _ = g.entered.fetchAdd(1, .acq_rel);
        try g.open.wait(g.io);
        return request;
    }
};

const Failer = struct {
    err: anyerror,

    fn handle(f: *Failer, _: *Context, _: []const u8) anyerror![]const u8 {
        return f.err;
    }
};

const big_body: [4096]u8 = @splat('b');

const Big = struct {
    len: usize,

    fn handle(b: *Big, _: *Context, _: []const u8) anyerror![]const u8 {
        return big_body[0..b.len];
    }
};

/// Waits until `counter` reaches `n`, ten seconds at most.
fn waitFor(io: std.Io, counter: *const std.atomic.Value(u32), n: u32) !void {
    const deadline: core.Deadline = .after(now(io), .fromSeconds(10));
    while (counter.load(.acquire) < n) {
        if (deadline.isExpired(now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

/// A server transport that hands its dispatcher to the test, which
/// delivers calls itself.
const TestTransport = struct {
    dispatcher: ?transport.Dispatcher = null,

    pub fn start(t: *TestTransport, io: std.Io, d: transport.Dispatcher) ServerTransport.StartError!void {
        _ = io;
        t.dispatcher = d;
    }

    pub fn drain(t: *TestTransport, io: std.Io) void {
        _ = t;
        _ = io;
    }

    pub fn close(t: *TestTransport, io: std.Io) void {
        _ = t;
        _ = io;
    }

    pub fn info(t: *TestTransport) transport.Info {
        _ = t;
        return .{ .name = "test", .propagates_cancellation = true };
    }
};

/// One call as a transport sees it: what the engine sent, and when and how
/// it released the call.
const TestCall = struct {
    incoming: Incoming = undefined,
    sends: std.atomic.Value(u32) = .init(0),
    releases: std.atomic.Value(u32) = .init(0),
    /// A `Reply` call after `release`.
    late: std.atomic.Value(bool) = .init(false),
    /// The first response.
    ok: bool = false,
    code: core.ErrorCode = .unknown,
    app_code: [64]u8 = undefined,
    app_code_len: usize = 0,
    message: [64]u8 = undefined,
    message_len: usize = 0,
    refused: bool = false,
    body_len: usize = 0,
    disposition: Reply.Disposition = .completed,
    released: std.Io.Event = .unset,
    /// When set, `release` reads it: how many handlers had ended by then.
    handler_ends: ?*const std.atomic.Value(u32) = null,
    ends_at_release: u32 = 0,
    /// When set, `release` reads them: whether this call's handler had
    /// started and ended by then.
    handler_started: ?*const std.atomic.Value(bool) = null,
    handler_ended: ?*const std.atomic.Value(bool) = null,
    started_at_release: bool = false,
    released_after_end: bool = false,
    /// The transport's lock of the call: `release` and a cancel by the
    /// test take it, so no cancel comes after `release`.
    mutex: std.Io.Mutex = .init,
    cancel_sent: bool = false,
    /// The first `send` records the response, then fails with this error.
    send_error: ?Reply.SendError = null,

    pub fn send(c: *TestCall, io: std.Io, response: *const model.Response) Reply.SendError!void {
        _ = io;
        if (c.releases.load(.acquire) != 0) c.late.store(true, .release);
        if (c.sends.fetchAdd(1, .acq_rel) != 0) return;
        c.refused = response.refused;
        c.body_len = response.body.len;
        switch (response.status) {
            .ok => c.ok = true,
            .failure => |failure| {
                c.code = failure.code;
                c.app_code_len = @min(failure.app_code.len, c.app_code.len);
                @memcpy(c.app_code[0..c.app_code_len], failure.app_code[0..c.app_code_len]);
                c.message_len = @min(failure.message.len, c.message.len);
                @memcpy(c.message[0..c.message_len], failure.message[0..c.message_len]);
            },
        }
        if (c.send_error) |err| return err;
    }

    pub fn release(c: *TestCall, io: std.Io, disposition: Reply.Disposition) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.releases.fetchAdd(1, .acq_rel) != 0) c.late.store(true, .release);
        if (c.handler_ends) |ends| c.ends_at_release = ends.load(.acquire);
        if (c.handler_started) |started| c.started_at_release = started.load(.acquire);
        if (c.handler_ended) |ended| c.released_after_end = ended.load(.acquire);
        c.disposition = disposition;
        c.released.set(io);
    }

    /// Cancels the call unless the engine has released it, under the lock
    /// of the call, as a transport does.
    fn cancelUnlessReleased(c: *TestCall, io: std.Io) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.releases.load(.acquire) != 0) return;
        c.cancel_sent = true;
        c.incoming.cancel(io);
    }

    fn waitReleased(c: *TestCall, io: std.Io) !void {
        waiting.untilSet(&c.released, io, .after(now(io), .fromSeconds(10))) catch |err| switch (err) {
            error.Timeout => return error.TestTimeout,
            error.Canceled => return error.Canceled,
        };
    }

    /// Exactly one response with this failure and one release.
    fn expectFailure(c: *TestCall, expected: model.Failure, refused: bool, disposition: Reply.Disposition) !void {
        try testing.expectEqual(@as(u32, 1), c.sends.load(.acquire));
        try testing.expectEqual(@as(u32, 1), c.releases.load(.acquire));
        try testing.expect(!c.late.load(.acquire));
        try testing.expect(!c.ok);
        try testing.expectEqual(expected.code, c.code);
        try testing.expectEqualStrings(expected.app_code, c.app_code[0..c.app_code_len]);
        try testing.expectEqualStrings(expected.message, c.message[0..c.message_len]);
        try testing.expectEqual(refused, c.refused);
        try testing.expectEqual(disposition, c.disposition);
    }

    fn expectOk(c: *TestCall, body_len: usize) !void {
        try testing.expectEqual(@as(u32, 1), c.sends.load(.acquire));
        try testing.expectEqual(@as(u32, 1), c.releases.load(.acquire));
        try testing.expect(!c.late.load(.acquire));
        try testing.expect(c.ok and !c.refused);
        try testing.expectEqual(body_len, c.body_len);
        try testing.expectEqual(Reply.Disposition.completed, c.disposition);
    }
};

/// Delivers one call the way a transport does: admit, fill the body,
/// start.
fn deliver(io: std.Io, d: transport.Dispatcher, head: *const transport.RequestHead, body: []const u8, call: *TestCall) !void {
    switch (d.admit(io, head, body.len)) {
        .rejected => return error.Refused,
        .accepted => |incoming| {
            @memcpy(incoming.body(), body);
            call.incoming = incoming;
            if (incoming.start(io, .init(call))) |_| return error.NotStarted;
        },
    }
}

fn headOf(io: std.Io, method: []const u8, budget: ?std.Io.Duration) transport.RequestHead {
    return .{
        .route = .{ .service = "test", .version = 1, .method = method },
        .request_id = @splat(9),
        .codec = "json",
        .timeout = budget,
        .received_at = now(io),
        .metadata = &.{},
    };
}

fn routeOf(method: []const u8) model.Route {
    return .{ .service = "test", .version = 1, .method = method };
}

fn requestOf(io: std.Io, method: []const u8, body: []const u8, budget: std.Io.Duration) transport.Request {
    return .{
        .route = routeOf(method),
        .request_id = @splat(5),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(now(io), budget)),
        .metadata = &.{},
        .body = body,
    };
}

fn expectFailureResponse(response: model.Response, expected: model.Failure) !void {
    switch (response.status) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(expected.code, failure.code);
            try testing.expectEqualStrings(expected.app_code, failure.app_code);
            try testing.expectEqualStrings(expected.message, failure.message);
        },
    }
}

test "a call runs its handler and the response comes back through the memory transport" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var echo: Echo = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("echo"), .handler = handlerOf(&echo) }},
    });
    defer server.deinit(io);
    try server.start(io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    for ([_][]const u8{ "{\"id\":1}", "", "\x00\xff\xfe not utf-8" }) |body| {
        const request = requestOf(io, "echo", body, .fromSeconds(5));
        const response = try client.call(io, &request, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
        try testing.expect(response.status == .ok);
        try testing.expect(!response.refused);
        try testing.expectEqualStrings(body, response.body);
    }
    // A route no method serves: refused at admission.
    const unknown = requestOf(io, "nothing", "{}", .fromSeconds(5));
    const refused = try client.call(io, &unknown, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
    try expectFailureResponse(refused, failures.unknown_method);
    try testing.expect(refused.refused);
    try server.shutdown(io);
}

fn mapTest(err: anyerror) ?model.Failure {
    return switch (err) {
        error.UserNotFound => .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        else => null,
    };
}

test "errors of a handler become failures: the contract's table, the framework's names, internal" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var not_found: Failer = .{ .err = error.UserNotFound };
    var unavailable: Failer = .{ .err = error.Unavailable };
    var unknown: Failer = .{ .err = error.DiskOnFire };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = routeOf("notFound"), .handler = handlerOf(&not_found), .map_error = mapTest },
            .{ .route = routeOf("unavailable"), .handler = handlerOf(&unavailable), .map_error = mapTest },
            .{ .route = routeOf("unknown"), .handler = handlerOf(&unknown), .map_error = mapTest },
        },
    });
    defer server.deinit(io);
    try server.start(io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const cases = [_]struct { []const u8, model.Failure }{
        .{ "notFound", .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" } },
        .{ "unavailable", failures.unavailable },
        .{ "unknown", failures.internal },
    };
    for (cases) |case| {
        const request = requestOf(io, case[0], "{}", .fromSeconds(5));
        const response = try client.call(io, &request, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
        try expectFailureResponse(response, case[1]);
        // The handler ran: not refused.
        try testing.expect(!response.refused);
    }
    try server.shutdown(io);
}

test "the deadline: deadline_exceeded goes out first, then the handler is canceled, release after its end" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var sleeper: Sleeper = .{ .io = io, .duration = .fromSeconds(30) };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("sleep"), .handler = handlerOf(&sleeper), .timeout = .fromMilliseconds(50) }},
    });
    defer server.deinit(io);
    try server.start(io);

    var call: TestCall = .{ .handler_ends = &sleeper.ended };
    const started_at = now(io);
    try deliver(io, test_transport.dispatcher.?, &headOf(io, "sleep", .fromSeconds(5)), "{}", &call);
    try call.waitReleased(io);
    const elapsed = started_at.durationTo(now(io));
    try testing.expect(elapsed.toMilliseconds() >= 50 and elapsed.toSeconds() < 10);
    if (sleeper.started.load(.acquire) == 1) {
        try call.expectFailure(failures.deadline_exceeded, false, .canceled);
        try testing.expectEqual(@as(u32, 1), call.ends_at_release);
    } else {
        // A machine so busy that the handler did not start within 50 ms:
        // the deadline still comes, once.
        try call.expectFailure(failures.deadline_exceeded, call.disposition == .not_started, call.disposition);
    }
    try server.shutdown(io);
}

test "a client that gives up: no response, the handler is canceled, release after its end" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var sleeper: Sleeper = .{ .io = io, .duration = .fromSeconds(30) };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("sleep"), .handler = handlerOf(&sleeper) }},
    });
    defer server.deinit(io);
    try server.start(io);

    var call: TestCall = .{ .handler_ends = &sleeper.ended };
    try deliver(io, test_transport.dispatcher.?, &headOf(io, "sleep", .fromSeconds(5)), "{}", &call);
    try sleeper.waitStarted(io, 1);
    // The second cancel does nothing. Each comes under the lock `release`
    // takes: the engine frees the call once `release` returns.
    call.cancelUnlessReleased(io);
    call.cancelUnlessReleased(io);
    try call.waitReleased(io);
    try testing.expectEqual(@as(u32, 0), call.sends.load(.acquire));
    try testing.expectEqual(@as(u32, 1), call.releases.load(.acquire));
    try testing.expectEqual(Reply.Disposition.canceled, call.disposition);
    try testing.expectEqual(@as(u32, 1), call.ends_at_release);
    const stats = test_transport.dispatcher.?.routeStats(0);
    try testing.expectEqual(@as(u64, 1), stats.errors);
    try testing.expectEqualStrings("rpc.cancelled", stats.last_error.?.appCode());
    try server.shutdown(io);
}

test "a handler that ends on its own: one response, completed" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var echo: Echo = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("echo"), .handler = handlerOf(&echo) }},
    });
    defer server.deinit(io);
    try server.start(io);

    var call: TestCall = .{};
    try deliver(io, test_transport.dispatcher.?, &headOf(io, "echo", null), "hello", &call);
    try call.waitReleased(io);
    try call.expectOk(5);
    const stats = test_transport.dispatcher.?.routeStats(0);
    try testing.expectEqual(@as(u64, 1), stats.requests);
    try testing.expectEqual(@as(u64, 0), stats.errors);
    try server.shutdown(io);
}

test "the queue: two run, two wait, a fifth is refused; the waiting ones run as places free" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var gate: Gate = .{ .io = io };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("gate"), .handler = handlerOf(&gate) }},
        .limits = .{ .max_active_tasks = 2, .queue_capacity = 2, .max_inflight = 4 },
    });
    defer server.deinit(io);
    // A failed check must not leave handlers waiting.
    defer gate.open.set(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    var calls: [4]TestCall = @splat(.{});
    for (&calls) |*call| try deliver(io, d, &headOf(io, "gate", .fromSeconds(10)), "q", call);
    try waitFor(io, &gate.entered, 2);
    try testing.expectEqual(@as(u32, 2), queuedCalls(io, &server));
    var fifth: TestCall = .{};
    try testing.expectError(error.Refused, deliver(io, d, &headOf(io, "gate", .fromSeconds(10)), "q", &fifth));
    try testing.expectEqual(@as(u32, 2), gate.entered.load(.acquire));

    gate.open.set(io);
    for (&calls) |*call| {
        try call.waitReleased(io);
        try call.expectOk(1);
    }
    try testing.expectEqual(@as(u32, 4), gate.entered.load(.acquire));
    try waitRetired(io, &server);
    try server.shutdown(io);
}

/// The calls in the server's queue, read under its lock.
fn queuedCalls(io: std.Io, server: *RawServer) u32 {
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    return server.queued;
}

/// Waits until the server has retired every call: a supervisor retires a
/// call right after its `release`.
fn waitRetired(io: std.Io, server: *const RawServer) !void {
    const deadline: core.Deadline = .after(now(io), .fromSeconds(10));
    while (server.inflight.load(.acquire) != 0) {
        if (deadline.isExpired(now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
}

test "a call whose deadline passes in the queue never starts: deadline_exceeded, refused, not_started" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var gate: Gate = .{ .io = io };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("gate"), .handler = handlerOf(&gate) }},
        .limits = .{ .max_active_tasks = 1, .queue_capacity = 2, .max_inflight = 3 },
    });
    defer server.deinit(io);
    defer gate.open.set(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    var running: TestCall = .{};
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(10)), "a", &running);
    try waitFor(io, &gate.entered, 1);
    var expiring: TestCall = .{};
    try deliver(io, d, &headOf(io, "gate", .fromMilliseconds(30)), "b", &expiring);
    var canceled: TestCall = .{};
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(10)), "c", &canceled);
    canceled.cancelUnlessReleased(io);
    try io.sleep(.fromMilliseconds(60), .awake);
    gate.open.set(io);

    try running.waitReleased(io);
    try running.expectOk(1);
    try expiring.waitReleased(io);
    try expiring.expectFailure(failures.deadline_exceeded, true, .not_started);
    // The client gave up while its call waited: nothing goes out.
    try canceled.waitReleased(io);
    try testing.expectEqual(@as(u32, 0), canceled.sends.load(.acquire));
    try testing.expectEqual(Reply.Disposition.not_started, canceled.disposition);
    try testing.expectEqual(@as(u32, 1), gate.entered.load(.acquire));
    try server.shutdown(io);
}

test "a response over max_response_bytes becomes resource_exhausted; one the transport cannot carry, a small failure" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{ .max_body_bytes = 1500 });
    defer memory.deinit(io);
    var over_limit: Big = .{ .len = 1025 };
    var over_transport: Big = .{ .len = 1501 };
    var fits: Big = .{ .len = 1024 };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = routeOf("overLimit"), .handler = handlerOf(&over_limit) },
            .{ .route = routeOf("overTransport"), .handler = handlerOf(&over_transport) },
            .{ .route = routeOf("fits"), .handler = handlerOf(&fits) },
        },
        .limits = .{ .max_response_bytes = 1024 },
    });
    defer server.deinit(io);
    try server.start(io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const options: ClientTransport.CallOptions = .{ .allocator = arena.allocator(), .max_response_bytes = 4096 };
    const fit = try client.call(io, &requestOf(io, "fits", "{}", .fromSeconds(5)), options);
    try testing.expectEqual(@as(usize, 1024), fit.body.len);
    try expectFailureResponse(try client.call(io, &requestOf(io, "overLimit", "{}", .fromSeconds(5)), options), failures.response_too_large);
    try server.shutdown(io);

    // A limit of the server above what the transport carries.
    var second: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("overTransport"), .handler = handlerOf(&over_transport) }},
        .limits = .{ .max_response_bytes = 4096 },
    });
    defer second.deinit(io);
    try second.start(io);
    try expectFailureResponse(try client.call(io, &requestOf(io, "overTransport", "{}", .fromSeconds(5)), options), failures.response_too_large);
    // The handler succeeded, but its client got a failure: an error.
    try waitRetired(io, &second);
    const stats = second.stats[0].snapshot(io);
    try testing.expectEqual(@as(u64, 1), stats.errors);
    try testing.expectEqual(core.ErrorCode.resource_exhausted, stats.last_error.?.code);
    try second.shutdown(io);
}

test "a response the transport loses counts as an error of its route, a contract breach too" {
    const io = testing.io;
    // A transport that returns Canceled from send is logged as a warning,
    // expected here.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var test_transport: TestTransport = .{};
    var echo: Echo = .{};
    var denied: Failer = .{ .err = error.PermissionDenied };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("echo"), .handler = handlerOf(&echo) },
            .{ .route = routeOf("denied"), .handler = handlerOf(&denied) },
        },
    });
    defer server.deinit(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    // Canceled breaks the contract: the engine blocks cancelation while it
    // sends.
    for ([_]Reply.SendError{ error.Closed, error.OutOfMemory, error.Unexpected, error.Canceled }, 1..) |err, i| {
        var call: TestCall = .{ .send_error = err };
        try deliver(io, d, &headOf(io, "echo", .fromSeconds(5)), "x", &call);
        try call.waitReleased(io);
        try testing.expectEqual(@as(u32, 1), call.sends.load(.acquire));
        try testing.expectEqual(Reply.Disposition.completed, call.disposition);
        try waitRetired(io, &server);
        const stats = d.routeStats(0);
        try testing.expectEqual(@as(u64, i), stats.errors);
        try testing.expectEqualStrings(failures.response_lost.app_code, stats.last_error.?.appCode());
    }

    // A failure that is lost counts as itself.
    var call: TestCall = .{ .send_error = error.Closed };
    try deliver(io, d, &headOf(io, "denied", .fromSeconds(5)), "x", &call);
    try call.waitReleased(io);
    try waitRetired(io, &server);
    const stats = d.routeStats(1);
    try testing.expectEqual(@as(u64, 1), stats.errors);
    try testing.expectEqualStrings(failures.permission_denied.app_code, stats.last_error.?.appCode());
    try server.shutdown(io);
}

test "no task: start refuses a call when no supervisor can start; a call whose handler gets no task is refused" {
    // An Io that runs one task at once: the stop task of the server.
    var one: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer one.deinit();
    {
        const io = one.io();
        var test_transport: TestTransport = .{};
        var echo: Echo = .{};
        var server: RawServer = try .init(testing.allocator, .{
            .transport = .init(&test_transport),
            .methods = &.{.{ .route = routeOf("echo"), .handler = handlerOf(&echo) }},
        });
        defer server.deinit(io);
        try server.start(io);
        var call: TestCall = .{};
        try testing.expectError(error.NotStarted, deliver(io, test_transport.dispatcher.?, &headOf(io, "echo", null), "x", &call));
        try testing.expectEqual(@as(u32, 0), call.sends.load(.acquire));
        try testing.expectEqual(@as(u32, 0), server.inflight.load(.acquire));
        try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
        try testing.expectEqualStrings("No task for the call", failures.no_task.message);
        try server.shutdown(io);
    }

    // Two tasks: the stop task and a supervisor, but none for the handler.
    var two: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(2) });
    defer two.deinit();
    {
        const io = two.io();
        var test_transport: TestTransport = .{};
        var echo: Echo = .{};
        var server: RawServer = try .init(testing.allocator, .{
            .transport = .init(&test_transport),
            .methods = &.{.{ .route = routeOf("echo"), .handler = handlerOf(&echo) }},
        });
        defer server.deinit(io);
        try server.start(io);
        var call: TestCall = .{};
        try deliver(io, test_transport.dispatcher.?, &headOf(io, "echo", null), "x", &call);
        try call.waitReleased(io);
        try call.expectFailure(failures.no_task, true, .not_started);
        try server.shutdown(io);
    }
}

/// Looks at everything `rpc.Context` gives a handler and keeps copies.
const Inspector = struct {
    same_io: bool = false,
    deadline: ?core.Deadline = null,
    has_token: bool = false,
    token_canceled: bool = true,
    trace: ?core.TraceContext = null,
    tracestate: [64]u8 = undefined,
    tracestate_len: usize = 0,
    route: [32]u8 = undefined,
    route_len: usize = 0,
    request_id: [16]u8 = undefined,
    first_a: [8]u8 = undefined,
    all_a: [8]u8 = undefined,
    all_a_len: usize = 0,
    entries: usize = 0,
    reserved_visible: bool = true,
    peer_name: [16]u8 = undefined,
    peer_name_len: usize = 0,
    transport_name: [16]u8 = undefined,
    transport_name_len: usize = 0,
    metadata_errors: [4]?Context.SetMetadataError = @splat(null),

    fn handle(s: *Inspector, ctx: *Context, request: []const u8) anyerror![]const u8 {
        s.same_io = ctx.io().vtable == testing.io.vtable;
        const op = ctx.operation();
        s.deadline = op.deadline;
        s.has_token = op.cancellation != null;
        s.token_canceled = op.isCancelled();
        if (op.trace) |trace| {
            s.trace = trace;
            s.tracestate_len = trace.state.header.len;
            @memcpy(s.tracestate[0..s.tracestate_len], trace.state.header);
            s.trace.?.state = .empty;
        }
        const route = ctx.route();
        s.route_len = (try std.fmt.bufPrint(&s.route, "{s}.v{d}.{s}", .{ route.service, route.version, route.method })).len;
        s.request_id = ctx.requestId();

        const metadata = ctx.metadata();
        s.first_a[0] = metadata.get("x-a").?[0];
        var values = metadata.getAll("x-a");
        while (values.next()) |value| : (s.all_a_len += 1) s.all_a[s.all_a_len] = value[0];
        var it = metadata.iterator();
        while (it.next()) |_| s.entries += 1;
        s.reserved_visible = metadata.get("traceparent") != null or metadata.get("tracestate") != null or
            metadata.get("authorization") != null or metadata.get("zefir-correlation-id") != null;

        s.peer_name_len = ctx.peer().name.len;
        @memcpy(s.peer_name[0..s.peer_name_len], ctx.peer().name);
        const info = ctx.transport();
        s.transport_name_len = info.name.len;
        @memcpy(s.transport_name[0..s.transport_name_len], info.name);

        try ctx.setResponseMetadata("x-r", "v1");
        try ctx.setResponseMetadata("x-r", "");
        for ([_][2][]const u8{ .{ "X-R", "v" }, .{ "traceparent", "v" }, .{ "zefir-hop", "v" }, .{ "x-r", " padded" } }, 0..) |pair, i| {
            ctx.setResponseMetadata(pair[0], pair[1]) catch |err| {
                s.metadata_errors[i] = err;
            };
        }
        return std.fmt.allocPrint(ctx.allocator(), "got {s}", .{request});
    }
};

test "rpc.Context gives a handler its call: io, operation, allocator, route, request id, metadata, peer, transport" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{ .peer_name = "client-7" });
    defer memory.deinit(io);
    var inspector: Inspector = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("inspect"), .handler = handlerOf(&inspector) }},
    });
    defer server.deinit(io);
    try server.start(io);

    const metadata = [_]model.Metadata.Entry{
        .{ .key = "x-a", .value = "1" },
        .{ .key = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ .key = "x-b", .value = "2" },
        .{ .key = "authorization", .value = "Bearer secret" },
        .{ .key = "tracestate", .value = "vendor=v" },
        .{ .key = "x-a", .value = "3" },
        .{ .key = "zefir-correlation-id", .value = "c-1" },
    };
    var request = requestOf(io, "inspect", "ping", .fromSeconds(5));
    request.metadata = &metadata;
    request.request_id = @splat(0xab);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sent_at = now(io);
    const response = try memory.clientTransport().call(io, &request, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });

    try testing.expect(response.status == .ok);
    try testing.expectEqualStrings("got ping", response.body);
    try testing.expectEqual(@as(usize, 2), response.metadata.len);
    try testing.expectEqualStrings("x-r", response.metadata[0].key);
    try testing.expectEqualStrings("v1", response.metadata[0].value);
    try testing.expectEqualStrings("", response.metadata[1].value);

    try testing.expect(inspector.same_io);
    const deadline = inspector.deadline.?;
    try testing.expect(deadline.expires.nanoseconds <= sent_at.addDuration(.fromSeconds(5)).nanoseconds);
    try testing.expect(!deadline.isExpired(sent_at));
    try testing.expect(inspector.has_token and !inspector.token_canceled);
    const trace = inspector.trace.?;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &trace.trace_id.toHex());
    try testing.expect(!std.mem.eql(u8, "00f067aa0ba902b7", &trace.span_id.toHex()));
    try testing.expect(trace.span_id.isValid() and trace.flags.sampled and !trace.is_remote);
    try testing.expectEqualStrings("vendor=v", inspector.tracestate[0..inspector.tracestate_len]);
    try testing.expectEqualStrings("test.v1.inspect", inspector.route[0..inspector.route_len]);
    try testing.expectEqual(request.request_id, inspector.request_id);
    try testing.expectEqual(@as(u8, '1'), inspector.first_a[0]);
    try testing.expectEqualStrings("13", inspector.all_a[0..inspector.all_a_len]);
    try testing.expectEqual(@as(usize, 3), inspector.entries);
    try testing.expect(!inspector.reserved_visible);
    try testing.expectEqualStrings("client-7", inspector.peer_name[0..inspector.peer_name_len]);
    try testing.expectEqualStrings("memory", inspector.transport_name[0..inspector.transport_name_len]);
    for (inspector.metadata_errors) |err| try testing.expectEqual(@as(?Context.SetMetadataError, error.InvalidMetadata), err);
    try server.shutdown(io);
}

/// Adds response metadata until the limits refuse.
const MetadataFiller = struct {
    refused_entry: ?Context.SetMetadataError = null,
    refused_bytes: ?Context.SetMetadataError = null,

    fn handle(s: *MetadataFiller, ctx: *Context, _: []const u8) anyerror![]const u8 {
        try ctx.setResponseMetadata("x-1", "a");
        // 2 + (3 + 3 + 1) so far; a value that would pass 1024 bytes.
        const long: [1024 - 2 - 7 - 3 - 3 + 1]u8 = @splat('v');
        ctx.setResponseMetadata("x-2", &long) catch |err| {
            s.refused_bytes = err;
        };
        try ctx.setResponseMetadata("x-2", long[0 .. long.len - 1]);
        ctx.setResponseMetadata("x-3", "") catch |err| {
            s.refused_entry = err;
        };
        return "";
    }
};

test "setResponseMetadata keeps the server's limits on entries and bytes" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var filler: MetadataFiller = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("fill"), .handler = handlerOf(&filler) }},
        .limits = .{ .max_metadata_entries = 2, .max_metadata_bytes = 1024 },
    });
    defer server.deinit(io);
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const response = try memory.clientTransport().call(io, &requestOf(io, "fill", "", .fromSeconds(5)), .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
    try testing.expect(response.status == .ok);
    try testing.expectEqual(@as(usize, 2), response.metadata.len);
    try testing.expectEqual(@as(usize, 1024), transport.metadataBytes(response.metadata));
    try testing.expectEqual(@as(?Context.SetMetadataError, error.ResourceExhausted), filler.refused_bytes);
    try testing.expectEqual(@as(?Context.SetMetadataError, error.ResourceExhausted), filler.refused_entry);
    try server.shutdown(io);
}

/// Fails in the ways `rpc.Context` offers.
const Failing = struct {
    mode: enum { exact, with_body, replaced },
    seen: ?model.Failure = null,
    mapped_recorded: ?model.Failure = null,
    mapped_unavailable: ?model.Failure = null,

    fn handle(s: *Failing, ctx: *Context, _: []const u8) anyerror![]const u8 {
        try ctx.setResponseMetadata("x-retry", "later");
        const locked: model.Failure = .{ .code = .failed_precondition, .app_code = "users.locked", .message = "Locked", .field = "id" };
        switch (s.mode) {
            .exact => {
                const err = ctx.fail(locked);
                s.seen = ctx.failure();
                s.mapped_recorded = ctx.mapError(err);
                s.mapped_unavailable = ctx.mapError(error.Unavailable);
                return err;
            },
            .with_body => return @import("Context.zig").failWithBody(ctx, locked, "{\"violations\":[]}"),
            // A failure recorded, then another error returned: the error
            // that comes out decides.
            .replaced => {
                const recorded = ctx.fail(locked);
                std.debug.assert(recorded == error.RpcFailure);
                return error.PermissionDenied;
            },
        }
    }
};

test "ctx.fail sends exactly its failure, with the response metadata; another error returned instead decides" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var exact: Failing = .{ .mode = .exact };
    var with_body: Failing = .{ .mode = .with_body };
    var replaced: Failing = .{ .mode = .replaced };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = routeOf("exact"), .handler = handlerOf(&exact) },
            .{ .route = routeOf("withBody"), .handler = handlerOf(&with_body) },
            .{ .route = routeOf("replaced"), .handler = handlerOf(&replaced) },
        },
    });
    defer server.deinit(io);
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const options: ClientTransport.CallOptions = .{ .allocator = arena.allocator(), .max_response_bytes = 1024 };

    const first = try client.call(io, &requestOf(io, "exact", "", .fromSeconds(5)), options);
    const failure = first.status.failure;
    try testing.expectEqual(core.ErrorCode.failed_precondition, failure.code);
    try testing.expectEqualStrings("users.locked", failure.app_code);
    try testing.expectEqualStrings("id", failure.field.?);
    try testing.expectEqualStrings("", first.body);
    try testing.expectEqualStrings("later", first.metadata[0].value);
    try testing.expectEqualStrings("users.locked", exact.seen.?.app_code);
    try testing.expectEqualStrings("users.locked", exact.mapped_recorded.?.app_code);
    try testing.expectEqualStrings("rpc.unavailable", exact.mapped_unavailable.?.app_code);

    const second = try client.call(io, &requestOf(io, "withBody", "", .fromSeconds(5)), options);
    try testing.expectEqualStrings("users.locked", second.status.failure.app_code);
    try testing.expectEqualStrings("{\"violations\":[]}", second.body);

    const third = try client.call(io, &requestOf(io, "replaced", "", .fromSeconds(5)), options);
    try expectFailureResponse(third, failures.permission_denied);
    try server.shutdown(io);
}

/// A `std.Io` that starts the tasks of `io.concurrent` only once `gate` is
/// set, as a busy scheduler starts a handler's task late; everything else
/// goes to `testing.io`. A supervisor starts through the server's group, so
/// only the handler's task waits.
const LateStart = struct {
    var gate: std.Io.Event = .unset;
    var vtable: std.Io.VTable = undefined;

    fn io() std.Io {
        vtable = testing.io.vtable.*;
        vtable.concurrent = concurrent;
        return .{ .userdata = testing.io.userdata, .vtable = &vtable };
    }

    /// The task's own start and a copy of its arguments.
    const Late = struct {
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        context: [64]u8 align(16),
    };

    fn concurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) std.Io.ConcurrentError!*std.Io.AnyFuture {
        if (context.len > 64 or context_alignment.toByteUnits() > 16) return error.ConcurrencyUnavailable;
        var late: Late = .{ .start = start, .context = undefined };
        @memcpy(late.context[0..context.len], context);
        return testing.io.vtable.concurrent(userdata, result_len, result_alignment, std.mem.asBytes(&late), .of(Late), lateStart);
    }

    fn lateStart(context: *const anyopaque, result: *anyopaque) void {
        const late: *const Late = @ptrCast(@alignCast(context));
        gate.waitUncancelable(testing.io);
        late.start(&late.context, result);
    }
};

/// Counts the handlers that entered.
const Entering = struct {
    entered: std.atomic.Value(u32) = .init(0),

    fn handle(s: *Entering, _: *Context, request: []const u8) anyerror![]const u8 {
        _ = s.entered.fetchAdd(1, .acq_rel);
        return request;
    }
};

test "an outcome before the handler's task enters keeps the handler out: the call did not start" {
    const io = testing.io;
    const late_io = LateStart.io();
    LateStart.gate = .unset;
    var entering: Entering = .{};
    var test_transport: TestTransport = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("short"), .handler = handlerOf(&entering), .timeout = .fromMilliseconds(50) },
            .{ .route = routeOf("long"), .handler = handlerOf(&entering) },
        },
        .shutdown_grace = .zero,
    });
    defer server.deinit(io);
    // A failed check leaves no task at the gate: deinit waits for them.
    defer LateStart.gate.set(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    // The deadline passes while the handler's task waits to start: the
    // refusal goes out at once.
    var by_deadline: TestCall = .{};
    try deliver(late_io, d, &headOf(io, "short", .fromSeconds(5)), "", &by_deadline);
    try waitFor(io, &by_deadline.sends, 1);
    LateStart.gate.set(io);
    try by_deadline.waitReleased(io);
    try by_deadline.expectFailure(failures.deadline_exceeded, true, .not_started);

    // The client gives up before the task starts.
    LateStart.gate.reset();
    var by_client: TestCall = .{};
    try deliver(late_io, d, &headOf(io, "long", .fromSeconds(5)), "", &by_client);
    by_client.cancelUnlessReleased(io);
    LateStart.gate.set(io);
    try by_client.waitReleased(io);
    try testing.expectEqual(@as(u32, 0), by_client.sends.load(.acquire));
    try testing.expectEqual(Reply.Disposition.not_started, by_client.disposition);

    // The stop cancels a call whose handler has not entered: another
    // replica may run it (AMQP requeues it).
    LateStart.gate.reset();
    var by_stop: TestCall = .{};
    try deliver(late_io, d, &headOf(io, "long", .fromSeconds(5)), "", &by_stop);
    server.requestStop(io);
    try waitFor(io, &by_stop.sends, 1);
    LateStart.gate.set(io);
    try by_stop.waitReleased(io);
    try by_stop.expectFailure(failures.stopping, true, .not_started);
    try server.wait(io);
    try testing.expectEqual(@as(u32, 0), entering.entered.load(.acquire));
}

/// Stops only when the token of its call is canceled, ignoring
/// cancelation of its task: a handler that checks `ctx.operation()`.
const TokenWatcher = struct {
    started: std.atomic.Value(u32) = .init(0),
    saw_token: std.atomic.Value(u32) = .init(0),

    fn handle(s: *TokenWatcher, ctx: *Context, _: []const u8) anyerror![]const u8 {
        _ = s.started.fetchAdd(1, .acq_rel);
        const op = ctx.operation();
        while (!op.isCancelled()) ctx.io().sleep(.fromMilliseconds(1), .awake) catch {};
        _ = s.saw_token.fetchAdd(1, .acq_rel);
        return error.Cancelled;
    }
};

test "the token of a call is canceled by its deadline, by its client and by the stop" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var watcher: TokenWatcher = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("short"), .handler = handlerOf(&watcher), .timeout = .fromMilliseconds(300) },
            .{ .route = routeOf("long"), .handler = handlerOf(&watcher) },
        },
        .shutdown_grace = .zero,
    });
    defer server.deinit(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;
    // A handler that sees its token ends at once, maybe before the engine
    // cancels its task: canceled or completed, both right.
    const done: []const Reply.Disposition = &.{ .canceled, .completed };

    var by_deadline: TestCall = .{};
    try deliver(io, d, &headOf(io, "short", null), "", &by_deadline);
    try waitFor(io, &watcher.started, 1);
    try by_deadline.waitReleased(io);
    try by_deadline.expectFailure(failures.deadline_exceeded, false, by_deadline.disposition);
    try testing.expect(std.mem.findScalar(Reply.Disposition, done, by_deadline.disposition) != null);

    var by_client: TestCall = .{};
    try deliver(io, d, &headOf(io, "long", null), "", &by_client);
    try waitFor(io, &watcher.started, 2);
    by_client.cancelUnlessReleased(io);
    try by_client.waitReleased(io);
    try testing.expectEqual(@as(u32, 0), by_client.sends.load(.acquire));
    try testing.expect(std.mem.findScalar(Reply.Disposition, done, by_client.disposition) != null);

    var by_stop: TestCall = .{};
    try deliver(io, d, &headOf(io, "long", null), "", &by_stop);
    try waitFor(io, &watcher.started, 3);
    try server.shutdown(io);
    try by_stop.expectFailure(failures.stopped, false, by_stop.disposition);
    try testing.expect(std.mem.findScalar(Reply.Disposition, done, by_stop.disposition) != null);
    try testing.expectEqual(@as(u32, 3), watcher.saw_token.load(.acquire));
}

/// Ends at the deadline give or take a little: the body holds the index of
/// the call, which picks its own delay.
const RaceHandler = struct {
    io: std.Io,
    budget: std.Io.Duration,
    delays: []const i64,
    started: []std.atomic.Value(bool),
    ended: []std.atomic.Value(bool),

    fn handle(s: *RaceHandler, _: *Context, request: []const u8) anyerror![]const u8 {
        const i = std.mem.readInt(u32, request[0..4], .little);
        s.started[i].store(true, .release);
        defer s.ended[i].store(true, .release);
        try s.io.sleep(.fromNanoseconds(s.budget.nanoseconds + s.delays[i]), .awake);
        return "done";
    }
};

fn cancelLater(call: *TestCall, io: std.Io, delay: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(delay, .awake);
    call.cancelUnlessReleased(io);
}

test "Review Focus 1: the deadline, the client's cancel and the handler's end race; each call ends once" {
    const io = testing.io;
    const n = 1000;
    const batch = 25;
    const budget: std.Io.Duration = .fromMilliseconds(20);
    var prng: std.Random.DefaultPrng = .init(0x5eed_1000);
    const random = prng.random();
    const handler_delays = try testing.allocator.alloc(i64, n);
    defer testing.allocator.free(handler_delays);
    const cancel_delays = try testing.allocator.alloc(i64, n);
    defer testing.allocator.free(cancel_delays);
    for (handler_delays, cancel_delays) |*h, *c| {
        h.* = random.intRangeAtMost(i64, -std.time.ns_per_ms, std.time.ns_per_ms);
        c.* = random.intRangeAtMost(i64, -std.time.ns_per_ms, std.time.ns_per_ms);
    }
    const started = try testing.allocator.alloc(std.atomic.Value(bool), n);
    defer testing.allocator.free(started);
    @memset(started, .init(false));
    const ended = try testing.allocator.alloc(std.atomic.Value(bool), n);
    defer testing.allocator.free(ended);
    @memset(ended, .init(false));
    const calls = try testing.allocator.alloc(TestCall, n);
    defer testing.allocator.free(calls);

    var handler: RaceHandler = .{ .io = io, .budget = budget, .delays = handler_delays, .started = started, .ended = ended };
    var test_transport: TestTransport = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("race"), .handler = handlerOf(&handler), .timeout = budget }},
    });
    defer server.deinit(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    var first: usize = 0;
    while (first < n) : (first += batch) {
        var cancelers: [batch]?std.Io.Future(std.Io.Cancelable!void) = @splat(null);
        defer for (&cancelers) |*slot| if (slot.*) |*future| future.cancel(io) catch {};
        for (first..first + batch, &cancelers) |i, *slot| {
            calls[i] = .{ .handler_started = &started[i], .handler_ended = &ended[i] };
            var body: [4]u8 = undefined;
            std.mem.writeInt(u32, &body, @intCast(i), .little);
            try deliver(io, d, &headOf(io, "race", .fromSeconds(5)), &body, &calls[i]);
            slot.* = try io.concurrent(cancelLater, .{ &calls[i], io, .fromNanoseconds(budget.nanoseconds + cancel_delays[i]) });
        }
        for (calls[first .. first + batch]) |*call| try call.waitReleased(io);
        for (&cancelers) |*slot| {
            try slot.*.?.await(io);
            slot.* = null;
        }
    }

    var ok: u64 = 0;
    var deadline: u64 = 0;
    var canceled: u64 = 0;
    for (calls, started, 0..) |*call, *handler_started, i| {
        errdefer std.debug.print("call {d}: sends {d} releases {d} late {} started {} after_end {} disposition {t} ok {} code {t} refused {} cancel_sent {}\n", .{
            i,                       call.sends.load(.acquire), call.releases.load(.acquire), call.late.load(.acquire),
            call.started_at_release, call.released_after_end,   call.disposition,             call.ok,
            call.code,               call.refused,              call.cancel_sent,
        });
        // Exactly one release, last, after the handler really ended; a
        // handler that had not started by then never starts.
        try testing.expectEqual(@as(u32, 1), call.releases.load(.acquire));
        try testing.expect(!call.late.load(.acquire));
        try testing.expectEqual(call.started_at_release, handler_started.load(.acquire));
        if (call.started_at_release) try testing.expect(call.released_after_end);
        // Under load a call may start after its budget: then its handler
        // never runs, and the call is released as not started.
        if (call.disposition == .not_started) try testing.expect(!call.started_at_release);
        // One response, or none when the client's cancel won.
        switch (call.sends.load(.acquire)) {
            0 => {
                try testing.expect(call.cancel_sent);
                canceled += 1;
            },
            1 => if (call.ok) {
                try testing.expect(call.started_at_release and call.disposition == .completed);
                ok += 1;
            } else {
                try testing.expectEqual(core.ErrorCode.deadline_exceeded, call.code);
                // Refused exactly when the call never started.
                try testing.expectEqual(call.disposition == .not_started, call.refused);
                deadline += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(u64, n), ok + deadline + canceled);
    try waitRetired(io, &server);
    const stats = d.routeStats(0);
    try testing.expectEqual(@as(u64, n), stats.requests);
    try testing.expectEqual(deadline + canceled, stats.errors);
    try server.shutdown(io);
}

fn stopLater(server: *RawServer, io: std.Io, delay: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(delay, .awake);
    server.requestStop(io);
}

test "Review Focus 1 with the stop: the deadline, the client's cancel, the stop and the handler's end race; each call ends once" {
    const io = testing.io;
    // A stop ends its server: a server per round.
    const rounds = 50;
    const per_round = 20;
    const n = rounds * per_round;
    const budget: std.Io.Duration = .fromMilliseconds(20);
    var prng: std.Random.DefaultPrng = .init(0x5eed_2000);
    const random = prng.random();
    const handler_delays = try testing.allocator.alloc(i64, n);
    defer testing.allocator.free(handler_delays);
    const cancel_delays = try testing.allocator.alloc(i64, n);
    defer testing.allocator.free(cancel_delays);
    for (handler_delays, cancel_delays) |*h, *c| {
        h.* = random.intRangeAtMost(i64, -std.time.ns_per_ms, std.time.ns_per_ms);
        c.* = random.intRangeAtMost(i64, -std.time.ns_per_ms, std.time.ns_per_ms);
    }
    const started = try testing.allocator.alloc(std.atomic.Value(bool), n);
    defer testing.allocator.free(started);
    @memset(started, .init(false));
    const ended = try testing.allocator.alloc(std.atomic.Value(bool), n);
    defer testing.allocator.free(ended);
    @memset(ended, .init(false));
    const calls = try testing.allocator.alloc(TestCall, n);
    defer testing.allocator.free(calls);
    var handler: RaceHandler = .{ .io = io, .budget = budget, .delays = handler_delays, .started = started, .ended = ended };

    var counts: struct { ok: u64 = 0, deadline: u64 = 0, canceled: u64 = 0, stopped: u64 = 0, stopping: u64 = 0, refused_at_admission: u64 = 0 } = .{};
    for (0..rounds) |round| {
        var test_transport: TestTransport = .{};
        var server: RawServer = try .init(testing.allocator, .{
            .transport = .init(&test_transport),
            .methods = &.{.{ .route = routeOf("race"), .handler = handlerOf(&handler), .timeout = budget }},
            .shutdown_grace = .zero,
        });
        defer server.deinit(io);
        try server.start(io);
        const d = test_transport.dispatcher.?;

        // The stop comes as the first calls reach their deadline, while
        // the last ones are still delivered.
        const stop_delay = budget.nanoseconds + random.intRangeAtMost(i64, -std.time.ns_per_ms, std.time.ns_per_ms);
        var stopper = try io.concurrent(stopLater, .{ &server, io, .fromNanoseconds(stop_delay) });
        defer stopper.cancel(io) catch {};
        var cancelers: [per_round]?std.Io.Future(std.Io.Cancelable!void) = @splat(null);
        defer for (&cancelers) |*slot| if (slot.*) |*future| future.cancel(io) catch {};
        var admitted: [per_round]bool = @splat(false);
        const first = round * per_round;
        for (first..first + per_round, &cancelers, &admitted) |i, *slot, *ok| {
            calls[i] = .{ .handler_started = &started[i], .handler_ended = &ended[i] };
            var body: [4]u8 = undefined;
            std.mem.writeInt(u32, &body, @intCast(i), .little);
            deliver(io, d, &headOf(io, "race", .fromSeconds(5)), &body, &calls[i]) catch |err| switch (err) {
                // The grace of the stop is over: refused at admission,
                // never counted for the route.
                error.Refused => {
                    counts.refused_at_admission += 1;
                    continue;
                },
                error.NotStarted => return err,
            };
            ok.* = true;
            slot.* = try io.concurrent(cancelLater, .{ &calls[i], io, .fromNanoseconds(budget.nanoseconds + cancel_delays[i]) });
        }
        for (calls[first..][0..per_round], admitted) |*call, ok| if (ok) try call.waitReleased(io);
        for (&cancelers) |*slot| if (slot.*) |*future| {
            try future.await(io);
            slot.* = null;
        };
        try stopper.await(io);
        try server.wait(io);

        var round_errors: u64 = 0;
        var round_admitted: u64 = 0;
        for (calls[first..][0..per_round], started[first..][0..per_round], admitted, first..) |*call, *handler_started, ok, i| {
            if (!ok) continue;
            round_admitted += 1;
            errdefer std.debug.print("call {d}: sends {d} releases {d} late {} started {} after_end {} disposition {t} ok {} code {t} message {s} refused {} cancel_sent {}\n", .{
                i,                       call.sends.load(.acquire),         call.releases.load(.acquire), call.late.load(.acquire),
                call.started_at_release, call.released_after_end,           call.disposition,             call.ok,
                call.code,               call.message[0..call.message_len], call.refused,                 call.cancel_sent,
            });
            // Exactly one release, last, after the handler really ended; a
            // handler that had not started by then never starts.
            try testing.expectEqual(@as(u32, 1), call.releases.load(.acquire));
            try testing.expect(!call.late.load(.acquire));
            try testing.expectEqual(call.started_at_release, handler_started.load(.acquire));
            if (call.started_at_release) try testing.expect(call.released_after_end);
            if (call.disposition == .not_started) try testing.expect(!call.started_at_release);
            switch (call.sends.load(.acquire)) {
                // Only the client's cancel sends nothing.
                0 => {
                    try testing.expect(call.cancel_sent);
                    counts.canceled += 1;
                    round_errors += 1;
                },
                1 => if (call.ok) {
                    try testing.expect(call.started_at_release and call.disposition == .completed);
                    counts.ok += 1;
                } else {
                    round_errors += 1;
                    const message = call.message[0..call.message_len];
                    if (call.code == .deadline_exceeded) {
                        try testing.expectEqual(call.disposition == .not_started, call.refused);
                        counts.deadline += 1;
                    } else if (std.mem.eql(u8, message, failures.stopped.message)) {
                        // Stopped after its handler entered.
                        try testing.expect(call.started_at_release and !call.refused);
                        counts.stopped += 1;
                    } else {
                        // Stopped before its handler entered.
                        try testing.expectEqualStrings(failures.stopping.message, message);
                        try testing.expect(call.refused and call.disposition == .not_started);
                        counts.stopping += 1;
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        }
        const stats = server.stats[0].snapshot(io);
        try testing.expectEqual(round_admitted, stats.requests);
        try testing.expectEqual(round_errors, stats.errors);
    }
    // How many calls the stop meets depends on the timers of the machine;
    // the checks above hold for any mix.
    try testing.expectEqual(@as(u64, n), counts.ok + counts.deadline + counts.canceled + counts.stopped + counts.stopping + counts.refused_at_admission);
}

/// Ignores cancelation: waits until `release` is set, whatever happens.
const Deaf = struct {
    io: std.Io,
    release: std.Io.Event = .unset,
    entered: std.atomic.Value(u32) = .init(0),

    fn handle(s: *Deaf, _: *Context, _: []const u8) anyerror![]const u8 {
        _ = s.entered.fetchAdd(1, .acq_rel);
        s.release.waitUncancelable(s.io);
        return "late";
    }
};

test "Review Focus 4: a stop with calls in every state and a deaf handler: ShutdownTimeout, then deinit once it ends" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var deaf: Deaf = .{ .io = io };
    var gate: Gate = .{ .io = io };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("deaf"), .handler = handlerOf(&deaf) },
            .{ .route = routeOf("gate"), .handler = handlerOf(&gate) },
        },
        .limits = .{ .max_active_tasks = 3, .queue_capacity = 3, .max_inflight = 6 },
        .shutdown_grace = .fromMilliseconds(100),
    });
    defer server.deinit(io);
    // A failed check must not leave the deaf handler waiting for good.
    defer deaf.release.set(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    // Three run: a deaf one, one that honors cancelation, one whose client
    // gives up.
    var deaf_call: TestCall = .{};
    var running: TestCall = .{};
    var given_up: TestCall = .{};
    try deliver(io, d, &headOf(io, "deaf", .fromSeconds(30)), "", &deaf_call);
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(30)), "", &running);
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(30)), "", &given_up);
    try waitFor(io, &deaf.entered, 1);
    try waitFor(io, &gate.entered, 2);
    // Three wait: one starts when the client above gives up, one's deadline
    // passes in the queue, one waits until the grace ends.
    var moved_up: TestCall = .{};
    var expired: TestCall = .{};
    var waiting_call: TestCall = .{};
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(30)), "", &moved_up);
    try deliver(io, d, &headOf(io, "gate", .fromMilliseconds(30)), "", &expired);
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(30)), "", &waiting_call);
    try testing.expectEqual(@as(u32, 3), queuedCalls(io, &server));
    given_up.cancelUnlessReleased(io);
    try given_up.waitReleased(io);
    try waitFor(io, &gate.entered, 3);
    try io.sleep(.fromMilliseconds(50), .awake);

    const stop_began = now(io);
    try testing.expectError(error.ShutdownTimeout, server.shutdown(io));
    // The grace, then the second the canceled calls get.
    try testing.expect(stop_began.durationTo(now(io)).toMilliseconds() >= 1100);
    try testing.expectEqual(RawServer.State.draining, server.state());
    try testing.expect(!server.isReady());
    // A second shutdown says the same at once.
    try testing.expectError(error.ShutdownTimeout, server.shutdown(io));

    try testing.expectEqual(@as(u32, 0), given_up.sends.load(.acquire));
    try testing.expectEqual(Reply.Disposition.canceled, given_up.disposition);
    for ([_]*TestCall{ &running, &moved_up }) |call| {
        try call.waitReleased(io);
        try call.expectFailure(failures.stopped, false, .canceled);
    }
    for ([_]*TestCall{ &expired, &waiting_call }) |call| {
        try call.waitReleased(io);
        try call.expectFailure(failures.stopping, true, .not_started);
    }
    // The deaf one got its failure at once, but keeps its slot until its
    // handler ends.
    try testing.expectEqual(@as(u32, 1), deaf_call.sends.load(.acquire));
    try testing.expectEqual(@as(u32, 0), deaf_call.releases.load(.acquire));
    try testing.expectEqual(@as(u32, 1), server.inflight.load(.acquire));

    deaf.release.set(io);
    try deaf_call.waitReleased(io);
    try deaf_call.expectFailure(failures.stopped, false, .canceled);
    try server.wait(io);
    try testing.expectEqual(RawServer.State.stopped, server.state());
    try server.shutdown(io);
    try testing.expectEqual(@as(u32, 3), gate.entered.load(.acquire));
}

test "a call delivered while the server drains still runs within the grace" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var gate: Gate = .{ .io = io };
    var echo: Echo = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("gate"), .handler = handlerOf(&gate) },
            .{ .route = routeOf("echo"), .handler = handlerOf(&echo) },
        },
        .shutdown_grace = .fromSeconds(30),
    });
    defer server.deinit(io);
    defer gate.open.set(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    var held: TestCall = .{};
    try deliver(io, d, &headOf(io, "gate", .fromSeconds(30)), "h", &held);
    try waitFor(io, &gate.entered, 1);
    server.requestStop(io);
    try testing.expectEqual(RawServer.State.draining, server.state());
    try testing.expectError(error.InvalidState, server.start(io));
    var late: TestCall = .{};
    try deliver(io, d, &headOf(io, "echo", .fromSeconds(30)), "late", &late);
    try late.waitReleased(io);
    try late.expectOk(4);

    // The stop ends as soon as the last call does, long before the grace.
    gate.open.set(io);
    try held.waitReleased(io);
    try held.expectOk(1);
    try server.wait(io);
    try testing.expectEqual(RawServer.State.stopped, server.state());
}

/// Stops the server it serves, then answers.
const Stopper = struct {
    server: ?*RawServer = null,

    fn handle(s: *Stopper, ctx: *Context, request: []const u8) anyerror![]const u8 {
        s.server.?.requestStop(ctx.io());
        return request;
    }
};

test "requestStop from a handler: its call still gets its response, then the server stops" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var stopper: Stopper = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("stop"), .handler = handlerOf(&stopper) }},
    });
    defer server.deinit(io);
    stopper.server = &server;
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const response = try memory.clientTransport().call(io, &requestOf(io, "stop", "bye", .fromSeconds(5)), .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
    try testing.expectEqualStrings("bye", response.body);
    try server.wait(io);
    try testing.expectEqual(RawServer.State.stopped, server.state());
}

/// Allocates `len` bytes in the arena of its call.
const Hog = struct {
    len: usize,

    fn handle(h: *Hog, ctx: *Context, _: []const u8) anyerror![]const u8 {
        const buffer = try ctx.allocator().alloc(u8, h.len);
        @memset(buffer, 'h');
        return buffer[0..1];
    }
};

test "a handler that allocates past the memory of its call gets OutOfMemory: resource_exhausted, and the memory comes back" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var hog: Hog = .{ .len = 128 * 1024 };
    var modest: Hog = .{ .len = 1024 };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = routeOf("hog"), .handler = handlerOf(&hog) },
            .{ .route = routeOf("modest"), .handler = handlerOf(&modest) },
        },
        .limits = .{ .max_request_bytes = 1024, .max_request_memory_bytes = 64 * 1024, .max_live_request_memory_bytes = 64 * 1024 },
    });
    defer server.deinit(io);
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const options: ClientTransport.CallOptions = .{ .allocator = arena.allocator(), .max_response_bytes = 1024 };

    const refused = try client.call(io, &requestOf(io, "hog", "{}", .fromSeconds(5)), options);
    try expectFailureResponse(refused, failures.resource_exhausted);
    // The handler ran: not refused.
    try testing.expect(!refused.refused);
    try waitRetired(io, &server);
    // The memory the handler took is back: a call within the limits runs.
    const fits = try client.call(io, &requestOf(io, "modest", "{}", .fromSeconds(5)), options);
    try testing.expectEqualStrings("h", fits.body);
    try waitRetired(io, &server);
    try server.shutdown(io);
}

test "Review Focus 2: a claimed gigabyte and 10 000 metadata entries are refused before any allocation" {
    const io = testing.io;
    var test_transport: TestTransport = .{};
    var echo: Echo = .{};
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var server: RawServer = try .init(failing.allocator(), .{
        .transport = .init(&test_transport),
        .methods = &.{.{ .route = routeOf("echo"), .handler = handlerOf(&echo) }},
    });
    defer server.deinit(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;
    // From here on, any allocation of the server fails.
    failing.fail_index = failing.alloc_index;

    var head = headOf(io, "echo", .fromSeconds(5));
    switch (d.admit(io, &head, 1 << 30)) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |failure| try testing.expectEqualStrings(failures.request_too_large.message, failure.message),
    }
    const many = try testing.allocator.alloc(model.Metadata.Entry, 10_000);
    defer testing.allocator.free(many);
    @memset(many, .{ .key = "x-a", .value = "1" });
    head.metadata = many;
    switch (d.admit(io, &head, 1 << 30)) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |failure| try testing.expectEqualStrings(failures.metadata_too_large.message, failure.message),
    }
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));

    // A modest call does reach the allocator, which refuses it.
    var call: TestCall = .{};
    try testing.expectError(error.Refused, deliver(io, d, &headOf(io, "echo", .fromSeconds(5)), "", &call));
    try testing.expect(failing.has_induced_failure);
    try server.shutdown(io);
}

test "refusals at admission reach the client with their codes, marked refused; route stats count them all" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var echo: Echo = .{};
    var failer: Failer = .{ .err = error.Unavailable };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = routeOf("echo"), .handler = handlerOf(&echo) },
            .{ .route = routeOf("fail"), .handler = handlerOf(&failer) },
        },
    });
    defer server.deinit(io);
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const options: ClientTransport.CallOptions = .{ .allocator = arena.allocator(), .max_response_bytes = 1024 };

    for (0..3) |_| try testing.expect((try client.call(io, &requestOf(io, "echo", "x", .fromSeconds(5)), options)).status == .ok);
    for (0..2) |_| try expectFailureResponse(try client.call(io, &requestOf(io, "fail", "x", .fromSeconds(5)), options), failures.unavailable);

    var bad_metadata = requestOf(io, "echo", "x", .fromSeconds(5));
    bad_metadata.metadata = &.{.{ .key = "zefir-unknown", .value = "1" }};
    var bad_codec = requestOf(io, "echo", "x", .fromSeconds(5));
    bad_codec.codec = "msgpack";
    for ([_]struct { *const transport.Request, model.Failure }{
        .{ &bad_metadata, failures.invalid_metadata },
        .{ &bad_codec, failures.unsupported_codec },
    }) |case| {
        const response = try client.call(io, case[0], options);
        try expectFailureResponse(response, case[1]);
        try testing.expect(response.refused);
    }

    try waitRetired(io, &server);
    const stats = server.stats[0].snapshot(io);
    try testing.expectEqual(@as(u64, 5), stats.requests);
    try testing.expectEqual(@as(u64, 2), stats.errors);
    try testing.expectEqualStrings("rpc.unsupported_codec", stats.last_error.?.appCode());
    try testing.expect(stats.processing_time.nanoseconds > 0);
    const failing_route = server.stats[1].snapshot(io);
    try testing.expectEqual(@as(u64, 2), failing_route.requests);
    try testing.expectEqual(@as(u64, 2), failing_route.errors);
    try testing.expectEqualStrings("rpc.unavailable", failing_route.last_error.?.appCode());
    try server.shutdown(io);
}

/// What a transport's task does with the dispatcher while a cancelation of
/// the task is pending; the cancelation must survive all of it.
fn keepsCancelation(d: transport.Dispatcher, io: std.Io, calls: *[2]TestCall) !void {
    var never: std.Io.Event = .unset;
    never.wait(io) catch |err| switch (err) {
        error.Canceled => io.recancel(),
    };
    // Admitted and started: a supervisor starts, the handler answers.
    try deliver(io, d, &headOf(io, "echo", .fromSeconds(5)), "x", &calls[0]);
    // Admitted and abandoned.
    switch (d.admit(io, &headOf(io, "echo", .fromSeconds(5)), 16)) {
        .accepted => |incoming| incoming.abandon(io),
        .rejected => return error.TestUnexpectedResult,
    }
    // Refused, counted for its route.
    var refused = headOf(io, "echo", .fromSeconds(5));
    refused.codec = "msgpack";
    if (d.admit(io, &refused, 0) == .accepted) return error.TestUnexpectedResult;
    _ = d.service();
    _ = d.routeStats(0);
    // Started and canceled by its client.
    try deliver(io, d, &headOf(io, "sleep", .fromSeconds(5)), "", &calls[1]);
    calls[1].cancelUnlessReleased(io);
    d.fail(io, error.Unavailable, null);
    return io.checkCancel();
}

test "admit, start, abandon, cancel and fail keep a cancelation of the transport's task" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var test_transport: TestTransport = .{};
    var echo: Echo = .{};
    var sleeper: Sleeper = .{ .io = io, .duration = .fromSeconds(30) };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = .init(&test_transport),
        .methods = &.{
            .{ .route = routeOf("echo"), .handler = handlerOf(&echo) },
            .{ .route = routeOf("sleep"), .handler = handlerOf(&sleeper) },
        },
    });
    defer server.deinit(io);
    try server.start(io);

    var calls: [2]TestCall = @splat(.{});
    var task = try io.concurrent(keepsCancelation, .{ test_transport.dispatcher.?, io, &calls });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, task.cancel(io));
    try calls[0].waitReleased(io);
    try calls[0].expectOk(1);
    try calls[1].waitReleased(io);
    // Canceled before or after its handler started.
    try testing.expect(calls[1].disposition == .canceled or calls[1].disposition == .not_started);
    try testing.expectEqual(@as(u32, 0), calls[1].sends.load(.acquire));
    // The broken transport stopped the server.
    try testing.expectError(error.Unavailable, server.wait(io));
}

// The examples in the doc comments of `rpc.RawServer` and `rpc.Context`.

const Greeter = struct {
    greeting: []const u8,

    fn handle(ptr: *anyopaque, ctx: *Context, name: []const u8) anyerror![]const u8 {
        const greeter: *Greeter = @ptrCast(@alignCast(ptr));
        return std.fmt.allocPrint(ctx.allocator(), "{s}, {s}!", .{ greeter.greeting, name });
    }
};

fn getUser(ctx: *Context) anyerror![]const u8 {
    const op = ctx.operation();
    try op.check(std.Io.Clock.awake.now(ctx.io()));
    const tenant = ctx.metadata().get("x-tenant") orelse
        return ctx.fail(.{ .code = .invalid_argument, .app_code = "users.no_tenant", .message = "No tenant" });
    try ctx.setResponseMetadata("x-cache", "miss");
    return std.fmt.allocPrint(ctx.allocator(), "{{\"tenant\":\"{s}\"}}", .{tenant});
}

fn getUserHandler(_: *anyopaque, ctx: *Context, _: []const u8) anyerror![]const u8 {
    return getUser(ctx);
}

test "the examples of the doc comments work" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var greeter: Greeter = .{ .greeting = "Hello" };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = .{ .service = "greeter", .version = 1, .method = "greet" }, .handler = .{ .ptr = &greeter, .handle = Greeter.handle } },
            .{ .route = .{ .service = "greeter", .version = 1, .method = "getUser" }, .handler = .{ .ptr = &greeter, .handle = getUserHandler } },
        },
    });
    defer server.deinit(io);
    try server.start(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = memory.clientTransport();
    const options: ClientTransport.CallOptions = .{ .allocator = arena.allocator(), .max_response_bytes = 1024 };

    var greet = requestOf(io, "greet", "Ada", .fromSeconds(5));
    greet.route.service = "greeter";
    try testing.expectEqualStrings("Hello, Ada!", (try client.call(io, &greet, options)).body);

    var user = requestOf(io, "getUser", "{}", .fromSeconds(5));
    user.route.service = "greeter";
    try testing.expectEqualStrings("users.no_tenant", (try client.call(io, &user, options)).status.failure.app_code);
    user.metadata = &.{.{ .key = "x-tenant", .value = "acme" }};
    const found = try client.call(io, &user, options);
    try testing.expectEqualStrings("{\"tenant\":\"acme\"}", found.body);
    try testing.expectEqualStrings("miss", found.metadata[0].value);
    server.requestStop(io);
    try server.wait(io);
}
