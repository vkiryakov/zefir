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
    }

    pub fn release(c: *TestCall, io: std.Io, disposition: Reply.Disposition) void {
        if (c.releases.fetchAdd(1, .acq_rel) != 0) c.late.store(true, .release);
        if (c.handler_ends) |ends| c.ends_at_release = ends.load(.acquire);
        c.disposition = disposition;
        c.released.set(io);
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
    try call.expectFailure(failures.deadline_exceeded, false, .canceled);
    try testing.expectEqual(@as(u32, 1), call.ends_at_release);
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
    call.incoming.cancel(io);
    call.incoming.cancel(io);
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
    try testing.expectEqual(@as(u32, 2), server.queued);
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
    canceled.incoming.cancel(io);
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
    try second.shutdown(io);
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
            .{ .route = routeOf("short"), .handler = handlerOf(&watcher), .timeout = .fromMilliseconds(30) },
            .{ .route = routeOf("long"), .handler = handlerOf(&watcher) },
        },
        .shutdown_grace = .zero,
    });
    defer server.deinit(io);
    try server.start(io);
    const d = test_transport.dispatcher.?;

    var by_deadline: TestCall = .{};
    try deliver(io, d, &headOf(io, "short", null), "", &by_deadline);
    try by_deadline.waitReleased(io);
    try by_deadline.expectFailure(failures.deadline_exceeded, false, .canceled);

    var by_client: TestCall = .{};
    try deliver(io, d, &headOf(io, "long", null), "", &by_client);
    try waitFor(io, &watcher.started, 2);
    by_client.incoming.cancel(io);
    try by_client.waitReleased(io);
    try testing.expectEqual(@as(u32, 0), by_client.sends.load(.acquire));

    var by_stop: TestCall = .{};
    try deliver(io, d, &headOf(io, "long", null), "", &by_stop);
    try waitFor(io, &watcher.started, 3);
    try server.shutdown(io);
    try by_stop.expectFailure(failures.stopped, false, .canceled);
    try testing.expectEqual(@as(u32, 3), watcher.saw_token.load(.acquire));
}
