//! Tests of `rpc.RawClient`: through a client transport that records what
//! the engine sends, and end to end through the memory transport and
//! `rpc.RawServer`.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const failures = @import("../failures.zig");
const RawClient = @import("RawClient.zig");
const RawServer = @import("RawServer.zig");
const Context = @import("Context.zig").Context;
const ClientTransport = @import("../ClientTransport.zig");
const MemoryTransport = @import("../testing/MemoryTransport.zig");
const Credentials = @import("../credentials.zig").Credentials;

const testing = std.testing;

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

const echo_route: model.Route = .{ .service = "test", .version = 1, .method = "echo" };

/// A client transport that records each request and answers as the test
/// tells it.
const Recorder = struct {
    io: std.Io,
    /// Copies of the last request, in `arena`.
    arena: std.heap.ArenaAllocator,
    calls: u32 = 0,
    route: model.Route = undefined,
    request_id: [16]u8 = undefined,
    metadata: []const model.Metadata.Entry = &.{},
    body: []const u8 = "",
    deadline: ?core.Deadline = null,
    trace: ?core.TraceContext = null,
    answer: Answer = .{ .ok = "pong" },
    /// Canceled right before the answer, when set.
    cancel_token: ?*core.CancellationToken = null,

    const Answer = union(enum) {
        ok: []const u8,
        failure: model.Failure,
        err: ClientTransport.CallError,
        /// Answers "late" after sleeping this long, deadline or not: a
        /// response at the deadline.
        late: std.Io.Duration,
    };

    fn init(io: std.Io) Recorder {
        return .{ .io = io, .arena = .init(testing.allocator) };
    }

    fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    fn get(r: *Recorder, key: []const u8) ?[]const u8 {
        return (model.Metadata.View{ .entries = r.metadata }).get(key);
    }

    pub fn call(r: *Recorder, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions) ClientTransport.CallError!model.Response {
        r.calls += 1;
        {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const a = r.arena.allocator();
            const entries = try a.alloc(model.Metadata.Entry, request.metadata.len);
            for (request.metadata, entries) |entry, *copy| copy.* = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
            r.metadata = entries;
            r.body = try a.dupe(u8, request.body);
            r.route = .{ .service = try a.dupe(u8, request.route.service), .version = request.route.version, .method = try a.dupe(u8, request.route.method) };
        }
        r.request_id = request.request_id;
        r.deadline = request.ctx.deadline;
        r.trace = request.ctx.trace;
        if (r.cancel_token) |token| token.cancel();
        const body = switch (r.answer) {
            .ok => |body| body,
            .failure => |failure| return .{ .status = .{ .failure = failure } },
            .err => |err| {
                if (options.diagnostics) |d| d.set(.wait, err, "recorded error", .{});
                return err;
            },
            .late => |pause| late: {
                try io.sleep(pause, .awake);
                break :late "late";
            },
        };
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        return .{ .status = .ok, .body = try options.allocator.dupe(u8, body) };
    }

    pub fn info(r: *Recorder) transport.Info {
        _ = r;
        return .{ .name = "recorder" };
    }
};

fn expectFailure(result: RawClient.Result, expected: model.Failure) !void {
    switch (result.response.status) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(expected.code, failure.code);
            try testing.expectEqualStrings(expected.app_code, failure.app_code);
            try testing.expectEqualStrings(expected.message, failure.message);
        },
    }
}

test "a call goes out with its route, a random request id, its body and a deadline; the response comes back" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder) });
    defer client.deinit();

    var first = try client.call(io, .root, echo_route, "ping", .{});
    defer first.deinit();
    try testing.expect(first.sent);
    try testing.expect(first.response.status == .ok);
    try testing.expectEqualStrings("pong", first.response.body);
    try testing.expectEqualStrings("echo", recorder.route.method);
    try testing.expectEqualStrings("ping", recorder.body);
    try testing.expectEqualSlices(u8, &first.request_id, &recorder.request_id);
    // No trace and no credentials: no metadata at all.
    try testing.expectEqual(@as(usize, 0), recorder.metadata.len);

    var second = try client.call(io, .root, echo_route, "", .{});
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, &first.request_id, &second.request_id));

    // A failure of the server is a value, not an error.
    recorder.answer = .{ .failure = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" } };
    var failed = try client.call(io, .root, echo_route, "", .{});
    defer failed.deinit();
    try expectFailure(failed, recorder.answer.failure);
    try testing.expect(failed.sent);
}

test "the deadline: the earlier of the caller's and the timeout, the client's default without one" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder), .default_timeout = .fromSeconds(7) });
    defer client.deinit();
    const second = std.time.ns_per_s;

    const cases = [_]struct { ctx_budget: ?i64, timeout: ?i64, expected: i64 }{
        .{ .ctx_budget = null, .timeout = null, .expected = 7 * second },
        .{ .ctx_budget = null, .timeout = 2 * second, .expected = 2 * second },
        .{ .ctx_budget = 1 * second, .timeout = 10 * second, .expected = 1 * second },
        .{ .ctx_budget = 30 * second, .timeout = null, .expected = 7 * second },
    };
    for (cases) |case| {
        const before = now(io);
        const ctx: core.Context = if (case.ctx_budget) |budget| core.Context.root.withDeadline(.after(before, .fromNanoseconds(budget))) else .root;
        const timeout: ?std.Io.Duration = if (case.timeout) |t| .fromNanoseconds(t) else null;
        var result = try client.call(io, ctx, echo_route, "", .{ .timeout = timeout });
        result.deinit();
        const budget = before.durationTo(recorder.deadline.?.expires).nanoseconds;
        // The deadline is set right after `before`, well within a second.
        try testing.expect(budget >= case.expected and budget < case.expected + second);
    }
}

test "a canceled or expired context, and a timeout of zero or less, send nothing" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder) });
    defer client.deinit();

    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.call(io, core.Context.root.withCancellation(&token), echo_route, "", .{}));
    const expired = core.Context.root.withDeadline(.after(now(io), .zero));
    try testing.expectError(error.DeadlineExceeded, client.call(io, expired, echo_route, "", .{}));
    try testing.expectError(error.DeadlineExceeded, client.call(io, .root, echo_route, "", .{ .timeout = .zero }));
    try testing.expectError(error.DeadlineExceeded, client.call(io, .root, echo_route, "", .{ .timeout = .fromSeconds(-1) }));
    try testing.expectEqual(@as(u32, 0), recorder.calls);
}

test "the errors of the transport in the client's names; diagnostics reach the caller" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var client: RawClient = try .init(testing.allocator, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    const cases = [_]struct { MemoryTransport.InjectedError, RawClient.CallError }{
        .{ error.Unavailable, error.Unavailable },
        .{ error.AccessDenied, error.AccessDenied },
        .{ error.ConnectionLost, error.ConnectionLost },
        .{ error.TooManyPendingRequests, error.TooManyPendingRequests },
        .{ error.RequestTooLarge, error.RequestTooLarge },
        .{ error.ResponseTooLarge, error.ResponseTooLarge },
        .{ error.ProtocolViolation, error.ProtocolViolation },
        .{ error.UnsupportedProtocol, error.UnsupportedProtocol },
        .{ error.Closed, error.ClientClosed },
        .{ error.OutOfMemory, error.OutOfMemory },
        .{ error.Unexpected, error.TransportFailed },
        .{ error.Timeout, error.DeadlineExceeded },
    };
    for (cases) |case| {
        memory.failNext(case[0]);
        var diagnostics: transport.Diagnostics = .{};
        try testing.expectError(case[1], client.call(io, .root, echo_route, "", .{ .diagnostics = &diagnostics }));
        try testing.expectEqualStrings("error injected with failNext", diagnostics.message());
    }
    // No server: the memory transport has nobody to deliver to.
    try testing.expectError(error.Unavailable, client.call(io, .root, echo_route, "", .{}));
}

test "invalid metadata, routes and credentials are not sent: a failure with sent = false" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder) });
    defer client.deinit();

    for ([_]model.Metadata.Entry{
        .{ .key = "authorization", .value = "Bearer t" },
        .{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" },
        .{ .key = "zefir-correlation-id", .value = "c" },
        .{ .key = "zefir-anything", .value = "x" },
        .{ .key = "X-Upper", .value = "x" },
        .{ .key = "x-ok", .value = "line\nbreak" },
        .{ .key = "x-ok", .value = " lead" },
    }) |entry| {
        var result = try client.call(io, .root, echo_route, "", .{ .metadata = &.{ .{ .key = "x-fine", .value = "1" }, entry } });
        defer result.deinit();
        try testing.expect(!result.sent);
        try expectFailure(result, failures.invalid_metadata);
    }
    for ([_]model.Route{
        .{ .service = "test.v1", .version = 1, .method = "echo" },
        .{ .service = "test", .version = 0, .method = "echo" },
        .{ .service = "test", .version = 1, .method = "" },
        .{ .service = "test", .version = 1, .method = "*" },
    }) |route| {
        var result = try client.call(io, .root, route, "", .{});
        defer result.deinit();
        try testing.expect(!result.sent);
        try expectFailure(result, failures.invalid_route);
    }
    for ([_]Credentials{
        .{ .bearer = "line\nbreak" },
        .{ .bearer = "" },
        .{ .custom = " lead" },
        .{ .custom = "ünicode" },
    }) |credentials| {
        var result = try client.call(io, .root, echo_route, "", .{ .credentials = credentials });
        defer result.deinit();
        try testing.expect(!result.sent);
        try expectFailure(result, failures.invalid_authorization);
    }
    try testing.expectEqual(@as(u32, 0), recorder.calls);
}

test "the call is a span of the caller's trace: traceparent and tracestate go out; without a trace, none" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder) });
    defer client.deinit();

    var parent = try core.w3c.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    parent.state = try core.w3c.parseTracestate("vendor=value,other=1");
    var result = try client.call(io, core.Context.root.withTrace(parent), echo_route, "", .{ .metadata = &.{.{ .key = "x-a", .value = "1" }} });
    result.deinit();
    // The engine's keys come first, then the application's.
    try testing.expectEqual(@as(usize, 3), recorder.metadata.len);
    try testing.expectEqualStrings("traceparent", recorder.metadata[0].key);
    try testing.expectEqualStrings("tracestate", recorder.metadata[1].key);
    try testing.expectEqualStrings("x-a", recorder.metadata[2].key);
    const sent = try core.w3c.parseTraceparent(recorder.get("traceparent").?);
    try testing.expectEqual(parent.trace_id, sent.trace_id);
    // The parent-id on the wire is the call's own span, a child of the caller's.
    try testing.expect(!std.meta.eql(parent.span_id, sent.span_id));
    try testing.expectEqual(recorder.trace.?.span_id, sent.span_id);
    try testing.expect(sent.flags.sampled);
    try testing.expectEqualStrings("vendor=value,other=1", recorder.get("tracestate").?);

    // A tracestate that metadata cannot carry stays behind; the trace goes on.
    parent.state = try core.w3c.parseTracestate("vendor=value,\tother=1");
    var tabbed = try client.call(io, core.Context.root.withTrace(parent), echo_route, "", .{});
    tabbed.deinit();
    try testing.expect(recorder.get("traceparent") != null);
    try testing.expectEqual(@as(?[]const u8, null), recorder.get("tracestate"));

    var untraced = try client.call(io, .root, echo_route, "", .{});
    untraced.deinit();
    try testing.expectEqual(@as(usize, 0), recorder.metadata.len);
    try testing.expectEqual(@as(?core.TraceContext, null), recorder.trace);
}

/// Hands out "Bearer t<n>" for the n-th call, or fails.
const Provider = struct {
    asked: u32 = 0,
    fail: ?(error{ Unavailable, OutOfMemory } || std.Io.Cancelable) = null,

    fn provider(p: *Provider) Credentials {
        return .{ .provider = .{ .ptr = p, .get = get } };
    }

    fn get(ptr: *anyopaque, io: std.Io, ctx: core.Context, arena: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!Credentials {
        const p: *Provider = @ptrCast(@alignCast(ptr));
        p.asked += 1;
        // The provider sees the deadline of the call.
        std.debug.assert(ctx.deadline != null);
        if (p.fail) |err| return err;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        return .{ .bearer = try std.fmt.allocPrint(arena, "t{d}", .{p.asked}) };
    }
};

test "credentials: the client's by default, the call's, none for one call, a provider asked before every call" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var token = "client-token".*;
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder), .credentials = .{ .bearer = &token } });
    defer client.deinit();
    // init copied the credentials.
    token[0] = 'X';

    const cases = [_]struct { ?Credentials, ?[]const u8 }{
        .{ null, "Bearer client-token" },
        .{ .none, null },
        .{ .{ .bearer = "user-token" }, "Bearer user-token" },
        .{ .{ .basic = .{ .user = "user", .password = "pass" } }, "Basic dXNlcjpwYXNz" },
        .{ .{ .custom = "ApiKey k-1" }, "ApiKey k-1" },
    };
    for (cases) |case| {
        var result = try client.call(io, .root, echo_route, "", .{ .credentials = case[0], .metadata = &.{.{ .key = "x-a", .value = "1" }} });
        result.deinit();
        if (case[1]) |expected| {
            try testing.expectEqualStrings("authorization", recorder.metadata[0].key);
            try testing.expectEqualStrings(expected, recorder.metadata[0].value);
        } else try testing.expectEqual(@as(?[]const u8, null), recorder.get("authorization"));
    }

    var provider: Provider = .{};
    for (1..3) |n| {
        var result = try client.call(io, .root, echo_route, "", .{ .credentials = provider.provider() });
        result.deinit();
        var buffer: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "Bearer t{d}", .{n}), recorder.get("authorization").?);
    }
    try testing.expectEqual(@as(u32, 2), provider.asked);

    // A provider that cannot answer: Unavailable, and nothing goes out.
    const calls = recorder.calls;
    provider.fail = error.Unavailable;
    try testing.expectError(error.Unavailable, client.call(io, .root, echo_route, "", .{ .credentials = provider.provider() }));
    provider.fail = error.OutOfMemory;
    try testing.expectError(error.OutOfMemory, client.call(io, .root, echo_route, "", .{ .credentials = provider.provider() }));
    try testing.expectEqual(calls, recorder.calls);
}

test "a client with a provider as its credentials asks it for every call" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var provider: Provider = .{};
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder), .credentials = provider.provider() });
    defer client.deinit();
    for (0..3) |_| {
        var result = try client.call(io, .root, echo_route, "", .{});
        result.deinit();
    }
    try testing.expectEqual(@as(u32, 3), provider.asked);
    try testing.expectEqualStrings("Bearer t3", recorder.get("authorization").?);
}

test "a response at the deadline, or after the context was canceled, is not a success" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var client: RawClient = try .init(testing.allocator, .{ .transport = .init(&recorder) });
    defer client.deinit();

    recorder.answer = .{ .late = .fromMilliseconds(60) };
    try testing.expectError(error.DeadlineExceeded, client.call(io, .root, echo_route, "", .{ .timeout = .fromMilliseconds(20) }));

    var token: core.CancellationToken = .init;
    recorder.answer = .{ .ok = "pong" };
    recorder.cancel_token = &token;
    try testing.expectError(error.Cancelled, client.call(io, core.Context.root.withCancellation(&token), echo_route, "", .{}));
}

/// Waits on a gate in the handler; canceling the call ends the wait.
const Gate = struct {
    io: std.Io,
    open: std.Io.Event = .unset,
    entered: std.atomic.Value(u32) = .init(0),

    fn handle(g: *Gate, _: *Context, request: []const u8) anyerror![]const u8 {
        _ = g.entered.fetchAdd(1, .acq_rel);
        try g.open.wait(g.io);
        return request;
    }

    fn waitEntered(g: *Gate, n: u32) !void {
        const deadline: core.Deadline = .after(now(g.io), .fromSeconds(10));
        while (g.entered.load(.acquire) < n) {
            if (deadline.isExpired(now(g.io))) return error.TestTimeout;
            try g.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

fn handlerOf(impl: anytype) RawServer.Handler {
    const T = @typeInfo(@TypeOf(impl)).pointer.child;
    return .{ .ptr = impl, .handle = struct {
        fn handle(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.handle(ctx, request);
        }
    }.handle };
}

/// Answers with its request and remembers the request id and the span.
const Inspector = struct {
    request_id: [16]u8 = undefined,
    trace_id: ?core.TraceId = null,

    fn handle(s: *Inspector, ctx: *Context, request: []const u8) anyerror![]const u8 {
        s.request_id = ctx.requestId();
        s.trace_id = if (ctx.operation().trace) |trace| trace.trace_id else null;
        return request;
    }
};

const Failer = struct {
    fn handle(_: *Failer, _: *Context, _: []const u8) anyerror![]const u8 {
        return error.PermissionDenied;
    }
};

test "end to end through memory: the handler's response, its failure, a refusal" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var inspector: Inspector = .{};
    var failer: Failer = .{};
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{
            .{ .route = echo_route, .handler = handlerOf(&inspector) },
            .{ .route = .{ .service = "test", .version = 1, .method = "fail" }, .handler = handlerOf(&failer) },
        },
    });
    defer server.deinit(io);
    try server.start(io);
    var client: RawClient = try .init(testing.allocator, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    const parent = try core.w3c.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    var ok = try client.call(io, core.Context.root.withTrace(parent), echo_route, "{\"id\":1}", .{});
    defer ok.deinit();
    try testing.expect(ok.response.status == .ok);
    try testing.expectEqualStrings("{\"id\":1}", ok.response.body);
    try testing.expectEqualSlices(u8, &ok.request_id, &inspector.request_id);
    try testing.expectEqual(parent.trace_id, inspector.trace_id.?);

    var failed = try client.call(io, .root, .{ .service = "test", .version = 1, .method = "fail" }, "", .{});
    defer failed.deinit();
    try expectFailure(failed, failures.permission_denied);
    try testing.expect(!failed.response.refused);

    var refused = try client.call(io, .root, .{ .service = "test", .version = 1, .method = "nothing" }, "", .{});
    defer refused.deinit();
    try expectFailure(refused, failures.unknown_method);
    try testing.expect(refused.response.refused and refused.sent);
    try server.shutdown(io);
}

fn callTask(client: *RawClient, io: std.Io, route: model.Route) RawClient.CallError!void {
    var result = try client.call(io, .root, route, "", .{});
    result.deinit();
}

test "max_pending: one call more than the client allows is not sent" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .io = io };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = handlerOf(&gate) }},
    });
    defer server.deinit(io);
    try server.start(io);
    var client: RawClient = try .init(testing.allocator, .{ .transport = memory.clientTransport(), .max_pending = 1 });
    defer client.deinit();

    var first = try io.concurrent(callTask, .{ &client, io, echo_route });
    // A failed check below must not leave the handler waiting.
    defer gate.open.set(io);
    try gate.waitEntered(1);
    try testing.expectError(error.TooManyPendingRequests, client.call(io, .root, echo_route, "", .{}));
    gate.open.set(io);
    try first.await(io);
    var again = try client.call(io, .root, echo_route, "", .{});
    again.deinit();
    try server.shutdown(io);
}

const Observed = struct { result: RawClient.CallError!void, still_canceled: bool };

/// Calls, then looks whether a cancelation of its task is still there.
fn callAndLook(client: *RawClient, io: std.Io, route: model.Route, timeout: std.Io.Duration) Observed {
    var observed: Observed = .{ .result = {}, .still_canceled = false };
    if (client.call(io, .root, route, "", .{ .timeout = timeout })) |result| {
        var r = result;
        r.deinit();
    } else |err| observed.result = err;
    io.checkCancel() catch {
        observed.still_canceled = true;
    };
    return observed;
}

test "the caller's task canceled during the transport's call: Cancelled once, and the cancelation stays" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var gate: Gate = .{ .io = io };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = handlerOf(&gate) }},
    });
    defer server.deinit(io);
    try server.start(io);
    var client: RawClient = try .init(testing.allocator, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    var caller = try io.concurrent(callAndLook, .{ &client, io, echo_route, std.Io.Duration.fromSeconds(10) });
    defer gate.open.set(io);
    try gate.waitEntered(1);
    const observed = caller.cancel(io);
    try testing.expectError(error.Cancelled, observed.result);
    try testing.expect(observed.still_canceled);

    // The deadline is never Cancelled. The server's own deadline_exceeded
    // could come a moment before the client's deadline: it is lost here, so
    // the transport's Timeout decides.
    gate.open.reset();
    memory.loseNextResponse();
    const timed_out = callAndLook(&client, io, echo_route, .fromMilliseconds(30));
    try testing.expectError(error.DeadlineExceeded, timed_out.result);
    try testing.expect(!timed_out.still_canceled);
    gate.open.set(io);
    try server.shutdown(io);
}

/// An allocator over `testing.allocator` that looks for `needle` in every
/// block given back through it.
const Spotter = struct {
    needle: []const u8,
    spotted: bool = false,

    fn allocator(s: *Spotter) std.mem.Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return testing.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const s: *Spotter = @ptrCast(@alignCast(ptr));
        if (std.mem.find(u8, memory, s.needle) != null) s.spotted = true;
        testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

/// Hands out a bearer token with the secret, allocated in the call's arena.
const SecretProvider = struct {
    fn get(_: *anyopaque, io: std.Io, _: core.Context, arena: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!Credentials {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        return .{ .bearer = try arena.dupe(u8, "s3cr3t-provided") };
    }
};

test "the client wipes its copy of the credentials and the credentials of each call" {
    const io = testing.io;
    var recorder: Recorder = .init(io);
    defer recorder.deinit();
    var spotter: Spotter = .{ .needle = "s3cr3t" };
    var client: RawClient = try .init(spotter.allocator(), .{ .transport = .init(&recorder), .credentials = .{ .bearer = "s3cr3t-client" } });
    var state: u8 = 0;
    for ([_]?Credentials{
        null,
        .{ .basic = .{ .user = "svc", .password = "s3cr3t-basic" } },
        .{ .provider = .{ .ptr = &state, .get = SecretProvider.get } },
    }) |credentials| {
        var result = try client.call(io, .root, echo_route, "", .{ .credentials = credentials });
        result.deinit();
    }
    try testing.expectEqualStrings("Bearer s3cr3t-provided", recorder.get("authorization").?);
    client.deinit();
    try testing.expect(!spotter.spotted);
}
