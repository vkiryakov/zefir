//! `rpc.testing.Server`: the handlers of a service on a memory transport,
//! with the whole chain of `rpc.Server` (authentication, middleware, JSON,
//! validation, the mapping of errors), and clients on the same transport.
//! A service is tested without NATS and without a network:
//!
//! ```zig
//! test "getUser returns the user" {
//!     var users: UserHandler = .init(&repo, &fraud_check);
//!     var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "u1" } };
//!     var t = try rpc.testing.Server.init(std.testing.allocator, std.testing.io, .{
//!         .handlers = .{&users},
//!         .authenticator = &auth,
//!     });
//!     defer t.deinit();
//!
//!     var client = try t.client(.{ .credentials = .{ .bearer = "test" } });
//!     defer client.deinit();
//!
//!     var r = try client.call(std.testing.io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
//!     defer r.deinit();
//!     try std.testing.expectEqualStrings("Ada", r.outcome.ok.name);
//! }
//! ```
//!
//! Such a test also runs the compile-time checks of `rpc.Server.init` on
//! the handlers, so `zig build test` stops on a handler against its
//! contract. Tests of failures reach the transport's hooks through
//! `memory`: `t.memory.failNext(error.Unavailable)`, `t.memory.breakLink(io)`.

const std = @import("std");
const AppServer = @import("../app/Server.zig");
const AppClient = @import("../app/Client.zig");
const MemoryTransport = @import("MemoryTransport.zig");

const Server = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// The memory transport of the server and its clients, with hooks for
/// tests of failures.
memory: *MemoryTransport,
/// The running server.
server: *AppServer,

pub const InitError = AppServer.InitError || AppServer.StartError;

/// Builds and starts a server of `options`: those of `rpc.Server.init`
/// without `.transport`, that is `.handlers` and, if needed,
/// `.authenticator`, `.middleware`, `.limits` and `.shutdown_grace`. The
/// transport and the server live on the heap, so the value that `init`
/// returns may be moved. `gpa` is thread-safe, as `std.testing.allocator`
/// is: handlers and clients allocate from their own tasks.
pub fn init(gpa: std.mem.Allocator, io: std.Io, options: anytype) InitError!Server {
    comptime check(serverOptionsProblem(@TypeOf(options)));
    const memory = try gpa.create(MemoryTransport);
    errdefer gpa.destroy(memory);
    memory.* = try .init(gpa, .{});
    errdefer memory.deinit(io);
    const server = try gpa.create(AppServer);
    errdefer gpa.destroy(server);
    server.* = try .init(gpa, withTransport(options, memory.serverTransport()));
    errdefer server.deinit(io);
    try server.start(io);
    return .{ .gpa = gpa, .io = io, .memory = memory, .server = server };
}

/// A client on the server's transport, built from `options`: those of
/// `rpc.Client.init` without `.transport`, such as
/// `.{ .credentials = .{ .bearer = "test" } }` or `.{}`. Its `deinit`
/// comes before the server's.
pub fn client(t: *Server, options: anytype) error{OutOfMemory}!AppClient {
    comptime check(clientOptionsProblem(@TypeOf(options)));
    return AppClient.init(t.gpa, withTransport(options, t.memory.clientTransport()));
}

/// Stops the server, waits for the calls it runs, and frees the server and
/// the transport. No client call may be in flight: it would meet a freed
/// transport. The wait has no limit: a handler deaf to cancelation keeps
/// `deinit` waiting past `shutdown_grace`, 10 seconds by default.
pub fn deinit(t: *Server) void {
    t.server.deinit(t.io);
    t.gpa.destroy(t.server);
    t.memory.deinit(t.io);
    t.gpa.destroy(t.memory);
    t.* = undefined;
}

fn check(comptime problem: ?[]const u8) void {
    if (problem) |message| @compileError(message);
}

/// The options of `rpc.testing.Server.init`, of type `O`: a struct literal
/// without `.transport`. `rpc.Server.init` checks the rest.
fn serverOptionsProblem(comptime O: type) ?[]const u8 {
    const at = "rpc.testing.Server.init: ";
    if (!isStructLiteral(O)) return at ++ "options must be a struct literal such as .{ .handlers = .{&users} }, got " ++ @typeName(O);
    if (@hasField(O, "transport")) return at ++ ".transport is not an option here: the server runs on a memory transport of its own";
    return null;
}

/// The options of `client`: a struct literal without `.transport`;
/// `rpc.Client.init` checks the rest.
fn clientOptionsProblem(comptime O: type) ?[]const u8 {
    const at = "rpc.testing.Server.client: ";
    if (!isStructLiteral(O)) return at ++ "options must be a struct literal such as .{ .credentials = .{ .bearer = \"test\" } } or .{}, got " ++ @typeName(O);
    if (@hasField(O, "transport")) return at ++ ".transport is not an option here: clients use the server's memory transport";
    return null;
}

/// A struct that is not a tuple, or the empty literal `.{}`.
fn isStructLiteral(comptime O: type) bool {
    return switch (@typeInfo(O)) {
        .@"struct" => |info| !info.is_tuple or info.field_names.len == 0,
        else => false,
    };
}

/// `O`, the type of a struct literal, with one more field: `transport` of
/// type `T`. Comptime fields stay comptime, with their values.
fn WithTransport(comptime O: type, comptime T: type) type {
    const info = @typeInfo(O).@"struct";
    const no_attributes = [_]std.lang.Type.Struct.FieldAttributes{.{}};
    return @Struct(.auto, null, info.field_names ++ .{"transport"}, info.field_types ++ .{T}, info.field_attrs ++ no_attributes);
}

/// `options` with `.transport = transport`: options are `anytype`, so a
/// new field means a new type.
fn withTransport(options: anytype, transport: anytype) WithTransport(@TypeOf(options), @TypeOf(transport)) {
    const O = @TypeOf(options);
    const info = @typeInfo(O).@"struct";
    var full: WithTransport(O, @TypeOf(transport)) = undefined;
    inline for (info.field_names, info.field_attrs) |name, attrs| {
        if (!attrs.@"comptime") @field(full, name) = @field(options, name);
    }
    full.transport = transport;
    return full;
}

const testing = std.testing;
const rpc = @import("../root.zig");

const Greeting = struct { text: []const u8 };
const Empty = struct {};
const GreetRequest = struct {
    name: []const u8,

    pub const field_rules = .{ .name = @import("validator").notEmpty };
};

const GreeterApi = rpc.Contract(.{
    .name = "greeter",
    .version = 1,
    .methods = .{
        .greet = rpc.method(GreetRequest, Greeting),
        .whoami = rpc.method(Empty, Greeting),
    },
});

const Greeter = struct {
    greeted: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = rpc.implement(GreeterApi, .{
        .methods = .{ .whoami = .{ .auth = .required } },
    });

    pub fn greet(self: *Greeter, ctx: *rpc.Context, req: GreetRequest) !Greeting {
        _ = self.greeted.fetchAdd(1, .monotonic);
        return .{ .text = try std.fmt.allocPrint(ctx.allocator(), "Hello, {s}!", .{req.name}) };
    }

    pub fn whoami(self: *Greeter, ctx: *rpc.Context, req: Empty) !Greeting {
        _ = self;
        _ = req;
        const identity = ctx.identity() orelse return error.Unauthenticated;
        return .{ .text = identity.subject };
    }
};

/// Starts a test server for `greeter` and returns it by value.
fn startGreeter(greeter: *Greeter, auth: *rpc.testing.StaticAuthenticator) !Server {
    return Server.init(testing.allocator, testing.io, .{ .handlers = .{greeter}, .authenticator = auth });
}

test "a test server serves its handlers to clients on its transport, and moves freely" {
    var greeter: Greeter = .{};
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "u1" } };
    var t = try startGreeter(&greeter, &auth);
    defer t.deinit();
    try testing.expectEqual(rpc.Server.State.running, t.server.state());
    try testing.expect(t.server.isReady());

    var plain = try t.client(.{});
    defer plain.deinit();
    var r = try plain.call(testing.io, .root, GreeterApi.greet, .{ .name = "Ann" }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("Hello, Ann!", r.outcome.ok.text);
    try testing.expectEqual(@as(u32, 1), greeter.greeted.load(.monotonic));

    // The whole chain: validation on both sides, authentication.
    var invalid = try plain.call(testing.io, .root, GreeterApi.greet, .{ .name = "" }, .{});
    defer invalid.deinit();
    try testing.expect(!invalid.sent);
    var anonymous = try plain.call(testing.io, .root, GreeterApi.whoami, .{}, .{});
    defer anonymous.deinit();
    try testing.expectEqual(@import("core").ErrorCode.unauthenticated, anonymous.outcome.failure.code);

    var signed = try t.client(.{ .credentials = .{ .bearer = "test" }, .default_timeout = std.Io.Duration.fromSeconds(5) });
    defer signed.deinit();
    var me = try signed.call(testing.io, .root, GreeterApi.whoami, .{}, .{});
    defer me.deinit();
    try testing.expectEqualStrings("u1", me.outcome.ok.text);
}

test "the hooks of the memory transport reach the clients of a test server" {
    var greeter: Greeter = .{};
    var auth: rpc.testing.StaticAuthenticator = .{};
    var t = try Server.init(testing.allocator, testing.io, .{
        .handlers = .{&greeter},
        .authenticator = &auth,
        .limits = .{ .max_active_tasks = 8 },
        .shutdown_grace = std.Io.Duration.fromSeconds(1),
    });
    defer t.deinit();
    var plain = try t.client(.{});
    defer plain.deinit();
    t.memory.failNext(error.Unavailable);
    try testing.expectError(error.Unavailable, plain.call(testing.io, .root, GreeterApi.greet, .{ .name = "Ann" }, .{}));
    var r = try plain.call(testing.io, .root, GreeterApi.greet, .{ .name = "Ann" }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("Hello, Ann!", r.outcome.ok.text);
}

/// Marks every response, so that the client sees that the server's function
/// link ran.
fn markResponse(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
    try ctx.setResponseMetadata("x-server-link", "fn");
    return next.run();
}

/// Counts the requests that the client's function link tagged.
const SeesTag = struct {
    tagged: std.atomic.Value(u32) = .init(0),

    pub fn run(self: *SeesTag, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        if (ctx.metadata().get("x-client-link") != null) _ = self.tagged.fetchAdd(1, .monotonic);
        return next.run();
    }
};

fn tagRequest(ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void {
    try ctx.addMetadata("x-client-link", "fn");
    return next.run();
}

/// Counts the successes that a link of the client sees.
const CountsSuccess = struct {
    ok: u32 = 0,

    pub fn run(self: *CountsSuccess, ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void {
        try next.run();
        if (ctx.response().?.status == .ok) self.ok += 1;
    }
};

test "middleware of the server and of its clients, functions and objects, passes through a test server" {
    var greeter: Greeter = .{};
    var auth: rpc.testing.StaticAuthenticator = .{};
    var sees: SeesTag = .{};
    var t = try Server.init(testing.allocator, testing.io, .{
        .handlers = .{&greeter},
        .authenticator = &auth,
        .middleware = .{ markResponse, &sees },
    });
    defer t.deinit();
    var counts: CountsSuccess = .{};
    var linked = try t.client(.{ .middleware = .{ tagRequest, &counts }, .credentials = .none });
    defer linked.deinit();

    var r = try linked.call(testing.io, .root, GreeterApi.greet, .{ .name = "Ann" }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("Hello, Ann!", r.outcome.ok.text);
    try testing.expectEqualStrings("fn", r.metadata().get("x-server-link").?);
    try testing.expectEqual(@as(u32, 1), sees.tagged.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), counts.ok);
}

test "a server that does not start leaves nothing behind" {
    var greeter: Greeter = .{};
    var auth: rpc.testing.StaticAuthenticator = .{};
    // Limits that contradict each other.
    try testing.expectError(error.InvalidConfiguration, Server.init(testing.allocator, testing.io, .{
        .handlers = .{&greeter},
        .authenticator = &auth,
        .limits = .{ .max_active_tasks = 0 },
    }));
    // Every allocation that fails, in turn.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: FailAt = .{ .parent = testing.allocator, .fail_index = fail_index };
        var t = Server.init(failing.allocator(), testing.io, .{ .handlers = .{&greeter}, .authenticator = &auth }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        t.deinit();
        if (!failing.induced.load(.monotonic)) break;
    }
}

/// Fails allocation number `fail_index` and every one after it, from any
/// task: the server's tasks may allocate while the test does.
const FailAt = struct {
    parent: std.mem.Allocator,
    fail_index: usize,
    count: std.atomic.Value(usize) = .init(0),
    induced: std.atomic.Value(bool) = .init(false),

    fn allocator(f: *FailAt) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *FailAt = @ptrCast(@alignCast(ptr));
        if (f.count.fetchAdd(1, .monotonic) >= f.fail_index) {
            f.induced.store(true, .monotonic);
            return null;
        }
        return f.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const f: *FailAt = @ptrCast(@alignCast(ptr));
        return f.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const f: *FailAt = @ptrCast(@alignCast(ptr));
        return f.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const f: *FailAt = @ptrCast(@alignCast(ptr));
        f.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "the options of a test server and of its clients leave out the transport" {
    try testing.expectEqual(@as(?[]const u8, null), comptime serverOptionsProblem(struct { handlers: struct { *Greeter } }));
    try testing.expectEqual(@as(?[]const u8, null), comptime clientOptionsProblem(@TypeOf(.{})));
    try testing.expectEqualStrings(
        "rpc.testing.Server.init: .transport is not an option here: the server runs on a memory transport of its own",
        comptime serverOptionsProblem(struct { transport: rpc.ServerTransport, handlers: struct { *Greeter } }).?,
    );
    try testing.expectEqualStrings(
        "rpc.testing.Server.init: options must be a struct literal such as .{ .handlers = .{&users} }, got *testing.Server.Greeter",
        comptime serverOptionsProblem(*Greeter).?,
    );
    try testing.expectEqualStrings(
        "rpc.testing.Server.client: .transport is not an option here: clients use the server's memory transport",
        comptime clientOptionsProblem(struct { transport: rpc.ClientTransport }).?,
    );
    try testing.expectEqualStrings(
        "rpc.testing.Server.client: options must be a struct literal such as .{ .credentials = .{ .bearer = \"test\" } } or .{}, got struct { u8 }",
        comptime clientOptionsProblem(struct { u8 }).?,
    );
}

test "a struct literal gets a transport, its comptime fields kept" {
    var users: u32 = 7;
    const full = withTransport(.{ .handlers = .{&users}, .limits = .{ .max_active_tasks = 1024 } }, @as(u8, 42));
    const Full = @TypeOf(full);
    try testing.expectEqual(@as(u8, 42), full.transport);
    try testing.expectEqual(@as(u32, 7), full.handlers[0].*);
    try testing.expectEqual(1024, full.limits.max_active_tasks);
    try testing.expect(@typeInfo(Full).@"struct".field_attrs[1].@"comptime");
    try testing.expect(!@typeInfo(Full).@"struct".field_attrs[0].@"comptime");
}
