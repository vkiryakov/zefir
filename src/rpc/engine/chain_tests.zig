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
