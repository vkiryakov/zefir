//! Tests of what runs between a transport and a handler: authentication,
//! and the middleware of the server and of the client. Calls go end to end
//! through the memory transport, `rpc.RawServer` and `rpc.RawClient`.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const failures = @import("../failures.zig");
const auth = @import("../auth.zig");
const RawClient = @import("RawClient.zig");
const RawServer = @import("RawServer.zig");
const Context = @import("Context.zig").Context;
const MemoryTransport = @import("../testing/MemoryTransport.zig");
const Credentials = @import("../credentials.zig").Credentials;
const AuthContext = auth.AuthContext;
const AuthError = auth.AuthError;
const IdentityView = auth.IdentityView;

const testing = std.testing;

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn routeOf(method: []const u8) model.Route {
    return .{ .service = "test", .version = 1, .method = method };
}

fn handlerOf(impl: anytype) RawServer.Handler {
    const T = @typeInfo(@TypeOf(impl)).pointer.child;
    return .{ .ptr = impl, .handle = struct {
        fn handle(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.handle(ctx, request);
        }
    }.handle };
}

/// A memory transport, a server and a client on it. Start it where it
/// stays: the server must not move once started.
const Fixture = struct {
    memory: MemoryTransport,
    server: RawServer,
    client: RawClient,

    /// The transports of the options are set here.
    fn start(f: *Fixture, io: std.Io, server_gpa: std.mem.Allocator, server_options: RawServer.Options, client_options: RawClient.Options) !void {
        f.memory = try .init(testing.allocator, .{});
        errdefer f.memory.deinit(io);
        var options = server_options;
        options.transport = f.memory.serverTransport();
        f.server = try .init(server_gpa, options);
        errdefer f.server.deinit(io);
        try f.server.start(io);
        var client = client_options;
        client.transport = f.memory.clientTransport();
        f.client = try .init(testing.allocator, client);
    }

    fn stop(f: *Fixture, io: std.Io) void {
        f.client.deinit();
        f.server.deinit(io);
        f.memory.deinit(io);
    }

    /// Calls `method` and returns the body of a success or the failure.
    fn call(f: *Fixture, io: std.Io, method: []const u8, options: RawClient.CallOptions) !RawClient.Result {
        return f.client.call(io, .root, routeOf(method), "", options);
    }
};

fn expectBody(result: *RawClient.Result, expected: []const u8) !void {
    defer result.deinit();
    switch (result.response.status) {
        .ok => try testing.expectEqualStrings(expected, result.response.body),
        .failure => |failure| {
            std.debug.print("unexpected failure {s}: {s}\n", .{ failure.app_code, failure.message });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailure(result: *RawClient.Result, expected: model.Failure) !void {
    defer result.deinit();
    switch (result.response.status) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(expected.code, failure.code);
            try testing.expectEqualStrings(expected.app_code, failure.app_code);
            try testing.expectEqualStrings(expected.message, failure.message);
        },
    }
}

/// Answers with who calls: "anonymous" or "<subject>@<tenant>".
const Who = struct {
    calls: std.atomic.Value(u32) = .init(0),

    fn handle(w: *Who, ctx: *Context, _: []const u8) anyerror![]const u8 {
        _ = w.calls.fetchAdd(1, .acq_rel);
        const identity = ctx.identity() orelse return "anonymous";
        return std.fmt.allocPrint(ctx.allocator(), "{s}@{s}", .{ identity.subject, identity.tenant_id orelse "-" });
    }
};

/// Knows the bearer token "alice" and the basic user "svc" with the
/// password "s3cr3t-pw"; records what it saw of the last call.
const Tokens = struct {
    calls: u32 = 0,
    saw_deadline: bool = false,
    saw_route: []const u8 = "",
    /// A copy: the metadata lives in the call's arena.
    saw_tenant: [8]u8 = @splat(0),
    saw_tenant_len: usize = 0,

    pub fn authenticate(t: *Tokens, ctx: *const AuthContext) AuthError!?IdentityView {
        t.calls += 1;
        t.saw_deadline = ctx.operation().deadline != null;
        t.saw_route = ctx.route().method;
        const tenant = ctx.metadata().get("x-tenant") orelse "";
        t.saw_tenant_len = @min(tenant.len, t.saw_tenant.len);
        @memcpy(t.saw_tenant[0..t.saw_tenant_len], tenant[0..t.saw_tenant_len]);
        // A wait through the call's io, as a store of sessions would.
        try ctx.io().sleep(.fromMilliseconds(1), .awake);
        return switch (ctx.credentials) {
            .none => null,
            .bearer => |token| if (std.mem.eql(u8, token, "alice")) .{
                .subject = try ctx.allocator().dupe(u8, "alice"),
                .tenant_id = "t-1",
                .permissions = &.{"users.read"},
            } else error.InvalidCredentials,
            .basic => |basic| if (std.mem.eql(u8, basic.user, "svc") and std.mem.eql(u8, basic.password, "s3cr3t-pw"))
                .{ .subject = "svc" }
            else
                error.InvalidCredentials,
            .custom, .provider => error.InvalidCredentials,
        };
    }
};

test "authentication: anonymous on an optional method, an identity for good credentials, a refusal for wrong ones" {
    const io = testing.io;
    var who: Who = .{};
    var tokens: Tokens = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .authenticator = .init(&tokens),
        .methods = &.{
            .{ .route = routeOf("optional"), .handler = handlerOf(&who) },
            .{ .route = routeOf("required"), .handler = handlerOf(&who), .auth = .required },
        },
    }, .{ .transport = undefined });
    defer f.stop(io);

    var anonymous = try f.call(io, "optional", .{});
    try expectBody(&anonymous, "anonymous");
    var alice = try f.call(io, "required", .{ .credentials = .{ .bearer = "alice" }, .metadata = &.{.{ .key = "x-tenant", .value = "t-1" }} });
    try expectBody(&alice, "alice@t-1");
    try testing.expect(tokens.saw_deadline);
    try testing.expectEqualStrings("required", tokens.saw_route);
    try testing.expectEqualStrings("t-1", tokens.saw_tenant[0..tokens.saw_tenant_len]);
    var basic = try f.call(io, "optional", .{ .credentials = .{ .basic = .{ .user = "svc", .password = "s3cr3t-pw" } } });
    try expectBody(&basic, "svc@-");
    const calls = who.calls.load(.acquire);

    // Required and anonymous; wrong credentials on either method.
    var required = try f.call(io, "required", .{});
    try expectFailure(&required, failures.authentication_required);
    for ([_][]const u8{ "optional", "required" }) |method| {
        for ([_]Credentials{
            .{ .bearer = "mallory" },
            .{ .basic = .{ .user = "svc", .password = "guess" } },
            .{ .custom = "ApiKey k-1" },
        }) |credentials| {
            var refused = try f.call(io, method, .{ .credentials = credentials });
            try expectFailure(&refused, failures.invalid_credentials);
        }
    }
    try testing.expectEqual(calls, who.calls.load(.acquire));
}

/// Returns what the test sets, after an optional pause.
const Scripted = struct {
    result: AuthError!?IdentityView = null,
    pause: ?std.Io.Duration = null,

    pub fn authenticate(s: *Scripted, ctx: *const AuthContext) AuthError!?IdentityView {
        if (s.pause) |pause| try ctx.io().sleep(pause, .awake);
        return s.result;
    }
};

test "the authenticator's errors and identities the engine refuses become their failures" {
    const io = testing.io;
    // A malformed identity is logged as a warning, expected here.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var who: Who = .{};
    var scripted: Scripted = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .authenticator = .init(&scripted),
        .methods = &.{.{ .route = routeOf("optional"), .handler = handlerOf(&who) }},
    }, .{ .transport = undefined });
    defer f.stop(io);

    const roles65: [65][]const u8 = @splat("r");
    const cases = [_]struct { AuthError!?IdentityView, model.Failure }{
        .{ error.InvalidCredentials, failures.invalid_credentials },
        .{ error.Unavailable, failures.unavailable },
        .{ error.OutOfMemory, failures.resource_exhausted },
        .{ error.DeadlineExceeded, failures.deadline_exceeded },
        .{ error.Cancelled, failures.cancelled },
        .{ IdentityView{ .subject = "u", .roles = &roles65 }, failures.identity_too_large },
        .{ IdentityView{ .subject = "" }, failures.internal },
        .{ IdentityView{ .subject = "u", .permissions = &.{"\xff"} }, failures.internal },
    };
    for (cases) |case| {
        scripted.result = case[0];
        var result = try f.call(io, "optional", .{});
        try expectFailure(&result, case[1]);
    }
    try testing.expectEqual(@as(u32, 0), who.calls.load(.acquire));
}

test "without an authenticator: anonymous calls pass, calls with credentials are refused" {
    const io = testing.io;
    var who: Who = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .methods = &.{.{ .route = routeOf("optional"), .handler = handlerOf(&who) }},
    }, .{ .transport = undefined });
    defer f.stop(io);

    var anonymous = try f.call(io, "optional", .{});
    try expectBody(&anonymous, "anonymous");
    var refused = try f.call(io, "optional", .{ .credentials = .{ .bearer = "alice" } });
    try expectFailure(&refused, failures.invalid_credentials);
    try testing.expectEqual(@as(u32, 1), who.calls.load(.acquire));
}

test "init refuses a method that requires an identity on a server without an authenticator" {
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(testing.io);
    var who: Who = .{};
    try testing.expectError(error.InvalidConfiguration, RawServer.init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &.{.{ .route = routeOf("required"), .handler = handlerOf(&who), .auth = .required }},
    }));
}

test "a slow authenticator is canceled at the deadline: deadline_exceeded at once, the handler never runs" {
    const io = testing.io;
    var who: Who = .{};
    var scripted: Scripted = .{ .pause = .fromSeconds(10) };
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .authenticator = .init(&scripted),
        .methods = &.{.{ .route = routeOf("optional"), .handler = handlerOf(&who) }},
    }, .{ .transport = undefined });
    defer f.stop(io);

    const started = now(io);
    // The server's deadline_exceeded, or the client's own deadline a moment
    // before it.
    if (f.call(io, "optional", .{ .timeout = .fromMilliseconds(50) })) |result| {
        var r = result;
        try expectFailure(&r, failures.deadline_exceeded);
    } else |err| try testing.expect(err == error.DeadlineExceeded);
    try testing.expect(started.durationTo(now(io)).toMilliseconds() < 5000);
    try testing.expectEqual(@as(u32, 0), who.calls.load(.acquire));
}

/// An allocator over `testing.allocator` that looks for `needle` in every
/// block given back through it.
const Spotter = struct {
    needle: []const u8,
    spotted: std.atomic.Value(bool) = .init(false),

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
        if (std.mem.find(u8, memory, s.needle) != null) s.spotted.store(true, .release);
        testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

test "the server wipes the decoded password of basic credentials before it frees the call" {
    const io = testing.io;
    var who: Who = .{};
    var tokens: Tokens = .{};
    var spotter: Spotter = .{ .needle = "s3cr3t-pw" };
    var f: Fixture = undefined;
    try f.start(io, spotter.allocator(), .{
        .transport = undefined,
        .authenticator = .init(&tokens),
        .methods = &.{.{ .route = routeOf("optional"), .handler = handlerOf(&who) }},
    }, .{ .transport = undefined });
    var stopped = false;
    defer if (!stopped) f.stop(io);
    var basic = try f.call(io, "optional", .{ .credentials = .{ .basic = .{ .user = "svc", .password = "s3cr3t-pw" } } });
    try expectBody(&basic, "svc@-");
    // The server frees a call after its response: stop it to be sure.
    f.stop(io);
    stopped = true;
    try testing.expect(!spotter.spotted.load(.acquire));
}

const middleware = @import("../middleware.zig");
const Middleware = middleware.Middleware;
const MiddlewareFn = middleware.MiddlewareFn;
const Next = middleware.Next;

/// What the links and the handler did, in order: "name>" before
/// `next.run()`, "<name" after it.
const Events = struct {
    items: [32][16]u8 = undefined,
    lens: [32]usize = undefined,
    count: usize = 0,

    fn add(e: *Events, comptime format: []const u8, name: []const u8) void {
        if (e.count < e.items.len) {
            const text = std.fmt.bufPrint(&e.items[e.count], format, .{name}) catch "?";
            e.lens[e.count] = text.len;
        }
        e.count += 1;
    }

    fn expect(e: *Events, expected: []const []const u8) !void {
        defer e.count = 0;
        try testing.expectEqual(expected.len, e.count);
        for (expected, 0..) |want, i| try testing.expectEqualStrings(want, e.items[i][0..e.lens[i]]);
    }
};

/// What the links of every test write to. Tests run one by one.
var trail: Events = .{};

/// A function link with a name, built at compile time.
fn traced(comptime name: []const u8) MiddlewareFn {
    return struct {
        fn run(_: *Context, next: *Next) anyerror!void {
            trail.add("{s}>", name);
            defer trail.add("<{s}", name);
            return next.run();
        }
    }.run;
}

/// An object link that the test steers, and what it saw.
const Probe = struct {
    name: []const u8,
    mode: Mode = .pass,
    /// What `next.run()` returned, if it failed.
    inner: ?anyerror = null,
    /// `ctx.failure()` after `next.run()`.
    inner_failure: [16]u8 = undefined,
    inner_failure_len: usize = 0,
    body_before: bool = false,
    body_after: ?usize = null,
    request_len: usize = 0,

    const Mode = enum {
        /// `next.run()` and its outcome.
        pass,
        /// Success without `next.run()`.
        stop,
        /// `error.PermissionDenied` without `next.run()`.
        deny,
        /// `next.run()` twice; the second's outcome.
        twice,
        /// `next.run()` twice, errors swallowed, success.
        twice_swallow,
        /// `next.run()`, its error swallowed, success.
        swallow,
        /// `next.run()`, then `error.Unavailable` whatever it returned.
        unavailable,
        /// `next.run()`, then `ctx.fail`.
        fail_after,
    };

    fn reset(p: *Probe, mode: Mode) void {
        p.* = .{ .name = p.name, .mode = mode };
    }

    pub fn run(p: *Probe, ctx: *Context, next: *Next) anyerror!void {
        trail.add("{s}>", p.name);
        defer trail.add("<{s}", p.name);
        p.request_len = ctx.requestBody().len;
        p.body_before = ctx.responseBody() != null;
        switch (p.mode) {
            .stop => return,
            .deny => return error.PermissionDenied,
            else => {},
        }
        const result = next.run();
        if (result) |_| {} else |err| p.inner = err;
        if (ctx.failure()) |failure| {
            p.inner_failure_len = @min(failure.app_code.len, p.inner_failure.len);
            @memcpy(p.inner_failure[0..p.inner_failure_len], failure.app_code[0..p.inner_failure_len]);
        }
        p.body_after = if (ctx.responseBody()) |body| body.len else null;
        return switch (p.mode) {
            .pass => result,
            .twice => next.run(),
            .twice_swallow => next.run() catch {},
            .swallow => {},
            .unavailable => error.Unavailable,
            .fail_after => ctx.fail(.{ .code = .aborted, .app_code = "test.aborted", .message = "Aborted after the handler" }),
            .stop, .deny => unreachable,
        };
    }
};

/// A handler that answers as the test sets.
const Answer = struct {
    mode: Mode = .ok,
    runs: u32 = 0,

    const Mode = enum { ok, user_not_found, locked };

    fn handle(a: *Answer, ctx: *Context, _: []const u8) anyerror![]const u8 {
        a.runs += 1;
        trail.add("{s}", "handler");
        return switch (a.mode) {
            .ok => "result",
            .user_not_found => error.UserNotFound,
            .locked => ctx.fail(.{ .code = .failed_precondition, .app_code = "test.locked", .message = "Locked" }),
        };
    }
};

fn mapUsers(err: anyerror) ?model.Failure {
    return switch (err) {
        error.UserNotFound => .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        else => null,
    };
}

test "middleware: the server's links, then the method's, then the handler, and back in reverse" {
    const io = testing.io;
    trail = .{};
    var s2: Probe = .{ .name = "s2" };
    var m2: Probe = .{ .name = "m2" };
    var answer: Answer = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .middleware = &.{ .of(traced("s1")), .of(&s2) },
        .methods = &.{
            .{ .route = routeOf("chain"), .handler = handlerOf(&answer), .middleware = &.{ .of(traced("m1")), .of(&m2), .of(traced("s1")) } },
            .{ .route = routeOf("bare"), .handler = handlerOf(&answer) },
        },
    }, .{ .transport = undefined });
    defer f.stop(io);

    var chain = try f.client.call(io, .root, routeOf("chain"), "request", .{});
    try expectBody(&chain, "result");
    // The same function on two levels runs twice.
    try trail.expect(&.{ "s1>", "s2>", "m1>", "m2>", "s1>", "handler", "<s1", "<m2", "<m1", "<s2", "<s1" });
    try testing.expectEqual(@as(usize, "request".len), m2.request_len);
    try testing.expect(!m2.body_before and !s2.body_before);
    try testing.expectEqual(@as(?usize, "result".len), m2.body_after);
    try testing.expectEqual(@as(?usize, "result".len), s2.body_after);
    var bare = try f.call(io, "bare", .{});
    try expectBody(&bare, "result");
    try trail.expect(&.{ "s1>", "s2>", "handler", "<s2", "<s1" });
}

test "the rules of next.run(): once, no success without it, swallowed errors stay, an outer error decides, mapping after the unwind" {
    const io = testing.io;
    // Links that break the rules are logged as warnings, expected here.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    trail = .{};
    var outer: Probe = .{ .name = "outer" };
    var inner: Probe = .{ .name = "inner" };
    var answer: Answer = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .middleware = &.{ .of(&outer), .of(&inner) },
        .methods = &.{.{ .route = routeOf("rules"), .handler = handlerOf(&answer), .map_error = mapUsers }},
    }, .{ .transport = undefined });
    defer f.stop(io);

    const not_found: model.Failure = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" };
    const aborted: model.Failure = .{ .code = .aborted, .app_code = "test.aborted", .message = "Aborted after the handler" };
    const locked: model.Failure = .{ .code = .failed_precondition, .app_code = "test.locked", .message = "Locked" };
    const Case = struct {
        outer: Probe.Mode = .pass,
        inner: Probe.Mode = .pass,
        answer: Answer.Mode = .ok,
        /// Null: success.
        expected: ?model.Failure,
        handler_runs: u32,
        /// What the outer link's next.run() returned.
        outer_saw: ?anyerror,
    };
    const cases = [_]Case{
        .{ .expected = null, .handler_runs = 1, .outer_saw = null },
        .{ .inner = .stop, .expected = failures.internal, .handler_runs = 0, .outer_saw = error.Internal },
        .{ .inner = .deny, .expected = failures.permission_denied, .handler_runs = 0, .outer_saw = error.PermissionDenied },
        .{ .inner = .twice, .expected = failures.internal, .handler_runs = 1, .outer_saw = error.Internal },
        // catch does not hide a second next.run(), on either level.
        .{ .inner = .twice_swallow, .outer = .swallow, .expected = failures.internal, .handler_runs = 1, .outer_saw = error.Internal },
        // The real Zig error reaches the links; it maps once, at the end.
        .{ .answer = .user_not_found, .expected = not_found, .handler_runs = 1, .outer_saw = error.UserNotFound },
        // A swallowed error stays the outcome.
        .{ .answer = .user_not_found, .inner = .swallow, .expected = not_found, .handler_runs = 1, .outer_saw = error.UserNotFound },
        .{ .answer = .user_not_found, .outer = .swallow, .expected = not_found, .handler_runs = 1, .outer_saw = error.UserNotFound },
        // An error a link returns decides: after a success, after an error.
        .{ .inner = .unavailable, .expected = failures.unavailable, .handler_runs = 1, .outer_saw = error.Unavailable },
        .{ .answer = .user_not_found, .inner = .unavailable, .expected = failures.unavailable, .handler_runs = 1, .outer_saw = error.Unavailable },
        .{ .outer = .fail_after, .expected = aborted, .handler_runs = 1, .outer_saw = null },
        .{ .inner = .fail_after, .expected = aborted, .handler_runs = 1, .outer_saw = error.RpcFailure },
        .{ .answer = .locked, .expected = locked, .handler_runs = 1, .outer_saw = error.RpcFailure },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("case {d}\n", .{i});
        outer.reset(case.outer);
        inner.reset(case.inner);
        answer.mode = case.answer;
        answer.runs = 0;
        var result = try f.call(io, "rules", .{});
        if (case.expected) |expected| try expectFailure(&result, expected) else try expectBody(&result, "result");
        try testing.expectEqual(case.handler_runs, answer.runs);
        try testing.expectEqual(case.outer_saw, outer.inner);
        // responseBody only after a next.run() that succeeded.
        try testing.expect(!outer.body_before);
        if (case.outer_saw != null) try testing.expectEqual(@as(?usize, null), outer.body_after);
        if (case.outer_saw == null) try testing.expectEqual(@as(?usize, "result".len), outer.body_after);
    }
    // ctx.failure() shows the links the failure set inside.
    outer.reset(.pass);
    inner.reset(.pass);
    answer.mode = .locked;
    var result = try f.call(io, "rules", .{});
    try expectFailure(&result, locked);
    try testing.expectEqualStrings("test.locked", outer.inner_failure[0..outer.inner_failure_len]);
    trail.count = 0;
}

/// Waits ten seconds before `next.run()`, as a slow external check would.
const Slow = struct {
    pub fn run(_: *Slow, ctx: *Context, next: *Next) anyerror!void {
        try ctx.io().sleep(.fromSeconds(10), .awake);
        return next.run();
    }
};

test "I/O in middleware is canceled by the deadline: deadline_exceeded at once, the handler never runs" {
    const io = testing.io;
    var slow: Slow = .{};
    var answer: Answer = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .middleware = &.{.of(&slow)},
        .methods = &.{.{ .route = routeOf("slow"), .handler = handlerOf(&answer) }},
    }, .{ .transport = undefined });
    defer f.stop(io);
    trail = .{};
    const started = now(io);
    // The server's deadline_exceeded, or the client's own deadline a moment
    // before it.
    if (f.call(io, "slow", .{ .timeout = .fromMilliseconds(50) })) |result| {
        var r = result;
        try expectFailure(&r, failures.deadline_exceeded);
    } else |err| try testing.expect(err == error.DeadlineExceeded);
    try testing.expect(started.durationTo(now(io)).toMilliseconds() < 5000);
    try testing.expectEqual(@as(u32, 0), answer.runs);
    trail.count = 0;
}

fn requirePermission(comptime permission: []const u8) MiddlewareFn {
    return struct {
        fn run(ctx: *Context, next: *Next) anyerror!void {
            const identity = ctx.identity() orelse return error.Unauthenticated;
            if (!identity.hasPermission(permission)) return error.PermissionDenied;
            return next.run();
        }
    }.run;
}

test "a permission check in middleware sees the identity of the authenticator" {
    const io = testing.io;
    var tokens: Tokens = .{};
    var who: Who = .{};
    var f: Fixture = undefined;
    try f.start(io, testing.allocator, .{
        .transport = undefined,
        .authenticator = .init(&tokens),
        .methods = &.{
            .{ .route = routeOf("read"), .handler = handlerOf(&who), .middleware = &.{.of(requirePermission("users.read"))} },
            .{ .route = routeOf("delete"), .handler = handlerOf(&who), .middleware = &.{.of(requirePermission("users.delete"))} },
        },
    }, .{ .transport = undefined, .credentials = .{ .bearer = "alice" } });
    defer f.stop(io);
    var read = try f.call(io, "read", .{});
    try expectBody(&read, "alice@t-1");
    var delete = try f.call(io, "delete", .{});
    try expectFailure(&delete, failures.permission_denied);
    var anonymous = try f.call(io, "read", .{ .credentials = .none });
    try expectFailure(&anonymous, failures.unauthenticated);
    try testing.expectEqual(@as(u32, 1), who.calls.load(.acquire));
}
