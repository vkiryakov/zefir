//! `rpc.RawServer`: the server engine. It takes calls from a server
//! transport, checks them against its routes and limits, runs each handler
//! in a task of its own with a deadline, answers through the transport and
//! stops gracefully, the same way on every transport. Bodies are bytes here;
//! `rpc.Server` builds the methods from the handlers of an application and
//! adds JSON and validation on top.
//!
//! ```zig
//! var server: rpc.RawServer = try .init(gpa, .{
//!     .transport = memory.serverTransport(),
//!     .methods = &.{.{ .route = .{ .service = "echo", .version = 1, .method = "say" }, .handler = echo.handler() }},
//! });
//! defer server.deinit(io);
//! try server.start(io);
//! // ... later, from any task:
//! server.requestStop(io);
//! try server.wait(io);
//! ```

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const rules = @import("../rules.zig");
const ServerTransport = @import("../ServerTransport.zig");
const Context = @import("Context.zig").Context;

const RawServer = @This();

gpa: std.mem.Allocator,
/// What `init` builds: the methods, their routes and the route table.
arena: std.heap.ArenaAllocator,
server_transport: ServerTransport,
methods: []const Method,
/// The key of a route, "service.v<version>.method", to its index in
/// `methods`.
table: std.StringArrayHashMapUnmanaged(u32),
limits: Limits,
shutdown_grace: std.Io.Duration,
/// What `Dispatcher.service` returns.
service_info: transport.Dispatcher.Service,

pub const Options = struct {
    /// The server side of a transport. The server drives it through
    /// `start`, `drain` and `close`; its owner creates it before the server
    /// and frees it after the server's `deinit`.
    transport: ServerTransport,
    /// Route to handler, bodies in bytes; at least one. `rpc.Server.init`
    /// builds this list from the handlers of an application. `init` copies
    /// the list and the route names; the handlers are borrowed and must
    /// outlive the server.
    methods: []const Method,
    limits: Limits = .{},
    /// How long the calls in flight may run after `requestStop` before the
    /// server cancels them.
    shutdown_grace: std.Io.Duration = .fromSeconds(10),
};

/// A route and its handler.
pub const Method = struct {
    route: model.Route,
    handler: Handler,
    /// The server's limit for a call of this method (`timeout_ms` of a
    /// contract method); null: `limits.default_timeout`. Never more than
    /// `limits.max_timeout`.
    timeout: ?std.Io.Duration = null,
    /// How errors of the application become failures, after the chain of
    /// middleware has unwound; `rpc.Server` builds it from the `.errors`
    /// table of the contract. Null: only the framework's own names map.
    map_error: ?*const fn (err: anyerror) ?model.Failure = null,
};

/// A handler on bytes.
pub const Handler = struct {
    ptr: *anyopaque,
    /// Returns the encoded body of a successful response, in memory from
    /// `ctx.allocator()`. Errors are plain Zig errors: they become a
    /// `Failure` after the chain of middleware has unwound. An exact
    /// failure is set with `ctx.fail`, which returns `error.RpcFailure`.
    handle: *const fn (ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8,
};

/// The limits of a server, as in rpc 1.6. `init` refuses limits that are
/// zero or contradict each other.
pub const Limits = struct {
    /// Handlers that run at once.
    max_active_tasks: u32 = 4096,
    /// Calls that wait for a free task, first in first out. They use up the
    /// budget of their deadline while they wait.
    queue_capacity: u32 = 256,
    /// Calls the server holds at once, from admission until their end; at
    /// most `max_active_tasks + queue_capacity`: every admitted call holds
    /// a task or a place in the queue.
    max_inflight: u32 = 4352,
    /// The largest request body.
    max_request_bytes: usize = 1 << 20,
    /// The largest response body; at least 1024 bytes, so that a failure
    /// always fits.
    max_response_bytes: usize = 1 << 20,
    /// The memory of one call: its body, the copy of its head and all its
    /// handler allocates with `ctx.allocator()`. At least
    /// `max_request_bytes`.
    max_request_memory_bytes: usize = 8 << 20,
    /// The memory of all calls at once. At least
    /// `max_request_memory_bytes`.
    max_live_request_memory_bytes: usize = 64 << 20,
    /// Metadata entries of a request or a response, repeated keys included.
    max_metadata_entries: u32 = 64,
    /// The size of the metadata of a request or a response, as
    /// `rpc.transport.metadataBytes` counts it; at least 1024.
    max_metadata_bytes: u32 = 16 * 1024,
    /// The deepest nesting of a JSON body, for `rpc.Server`.
    max_json_depth: u32 = 32,
    /// The most items of one JSON array or object, for `rpc.Server`.
    max_container_items: u32 = 100_000,
    /// The limit of a call whose method sets none.
    default_timeout: std.Io.Duration = .fromSeconds(3),
    /// No call runs longer, whatever its client or its method asks.
    max_timeout: std.Io.Duration = .fromSeconds(300),
};

/// `InvalidConfiguration`: no methods, a route name against the rules
/// (`[A-Za-z0-9_-]`, 1 to 64 characters, a version above 0), the same route
/// twice, a method timeout that is not positive, limits that are zero or
/// contradict each other, a negative shutdown grace.
pub const InitError = error{ InvalidConfiguration, OutOfMemory };

/// Checks the options and builds the route table. No I/O and no tasks.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!RawServer {
    if (options.methods.len == 0) return error.InvalidConfiguration;
    if (options.methods.len > std.math.maxInt(u32)) return error.InvalidConfiguration;
    if (!validLimits(options.limits) or options.shutdown_grace.nanoseconds < 0) return error.InvalidConfiguration;
    for (options.methods) |method| {
        rules.validateRoute(method.route) catch return error.InvalidConfiguration;
        if (method.timeout) |timeout| if (timeout.nanoseconds <= 0) return error.InvalidConfiguration;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const methods = try a.alloc(Method, options.methods.len);
    const routes = try a.alloc(model.Route, options.methods.len);
    var table: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try table.ensureTotalCapacity(a, options.methods.len);
    for (options.methods, methods, routes, 0..) |method, *copy, *route, i| {
        copy.* = method;
        copy.route.service = try a.dupe(u8, method.route.service);
        copy.route.method = try a.dupe(u8, method.route.method);
        route.* = copy.route;
        const key = try std.fmt.allocPrint(a, "{s}.v{d}.{s}", .{ route.service, route.version, route.method });
        const entry = table.getOrPutAssumeCapacity(key);
        if (entry.found_existing) return error.InvalidConfiguration;
        entry.value_ptr.* = @intCast(i);
    }
    return .{
        .gpa = gpa,
        .arena = arena,
        .server_transport = options.transport,
        .methods = methods,
        .table = table,
        .limits = options.limits,
        .shutdown_grace = options.shutdown_grace,
        .service_info = .{
            .routes = routes,
            .max_inflight = options.limits.max_inflight,
            .max_request_bytes = options.limits.max_request_bytes,
            .max_metadata_entries = options.limits.max_metadata_entries,
            .max_metadata_bytes = options.limits.max_metadata_bytes,
        },
    };
}

/// Frees the server.
pub fn deinit(server: *RawServer, io: std.Io) void {
    _ = io;
    server.arena.deinit();
    server.* = undefined;
}

/// The index of the method that serves `route`; null when none does.
fn lookup(server: *const RawServer, route: model.Route) ?u32 {
    if (!rules.isValidName(route.service) or !rules.isValidName(route.method)) return null;
    // Two names of at most 64 bytes, ".v", 5 digits and ".".
    var buffer: [2 * rules.max_name_bytes + 8]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "{s}.v{d}.{s}", .{ route.service, route.version, route.method }) catch return null;
    return server.table.get(key);
}

/// The smallest budget of a response body and of metadata: a failure must
/// always fit.
const min_budget_bytes = 1024;

fn validLimits(limits: Limits) bool {
    if (limits.max_active_tasks == 0 or limits.queue_capacity == 0 or limits.max_inflight == 0) return false;
    if (@as(u64, limits.max_inflight) > @as(u64, limits.max_active_tasks) + limits.queue_capacity) return false;
    if (limits.max_request_bytes == 0 or limits.max_request_bytes > limits.max_request_memory_bytes) return false;
    if (limits.max_request_memory_bytes > limits.max_live_request_memory_bytes) return false;
    if (limits.max_response_bytes < min_budget_bytes) return false;
    if (limits.max_metadata_entries == 0 or limits.max_metadata_bytes < min_budget_bytes) return false;
    if (limits.max_json_depth == 0 or limits.max_container_items == 0) return false;
    if (limits.default_timeout.nanoseconds <= 0 or limits.default_timeout.nanoseconds > limits.max_timeout.nanoseconds) return false;
    return true;
}

const testing = std.testing;
const MemoryTransport = @import("../testing/MemoryTransport.zig");

const NoHandler = struct {
    fn handle(_: *anyopaque, _: *Context, _: []const u8) anyerror![]const u8 {
        return error.Unexpected;
    }
};

var no_handler_state: u8 = 0;
const no_handler: Handler = .{ .ptr = &no_handler_state, .handle = NoHandler.handle };

fn methodOf(service: []const u8, version: u16, method: []const u8) Method {
    return .{ .route = .{ .service = service, .version = version, .method = method }, .handler = no_handler };
}

test "init builds the route table and the service the transport sees" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    // Route names that do not outlive init: the server keeps copies.
    var service_name = "users".*;
    const methods = [_]Method{
        methodOf(&service_name, 1, "getUser"),
        methodOf(&service_name, 2, "getUser"),
        methodOf("orders", 1, "list"),
    };
    var server: RawServer = try .init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .methods = &methods,
        .limits = .{ .max_inflight = 100, .max_request_bytes = 2048, .max_metadata_entries = 8, .max_metadata_bytes = 4096 },
    });
    defer server.deinit(io);
    service_name[0] = 'X';

    try testing.expectEqual(@as(?u32, 0), server.lookup(.{ .service = "users", .version = 1, .method = "getUser" }));
    try testing.expectEqual(@as(?u32, 1), server.lookup(.{ .service = "users", .version = 2, .method = "getUser" }));
    try testing.expectEqual(@as(?u32, 2), server.lookup(.{ .service = "orders", .version = 1, .method = "list" }));
    for ([_]model.Route{
        .{ .service = "users", .version = 3, .method = "getUser" },
        .{ .service = "users", .version = 1, .method = "getuser" },
        .{ .service = "Xsers", .version = 1, .method = "getUser" },
        .{ .service = "users.v1", .version = 1, .method = "getUser" },
        .{ .service = "users", .version = 1, .method = &@as([65]u8, @splat('a')) },
        .{ .service = "", .version = 1, .method = "getUser" },
    }) |route| try testing.expectEqual(@as(?u32, null), server.lookup(route));

    const service = server.service_info;
    try testing.expectEqual(@as(usize, 3), service.routes.len);
    try testing.expectEqualStrings("users", service.routes[0].service);
    try testing.expectEqual(@as(u16, 2), service.routes[1].version);
    try testing.expectEqualStrings("list", service.routes[2].method);
    try testing.expectEqual(@as(u32, 100), service.max_inflight);
    try testing.expectEqual(@as(usize, 2048), service.max_request_bytes);
    try testing.expectEqual(@as(u32, 8), service.max_metadata_entries);
    try testing.expectEqual(@as(u32, 4096), service.max_metadata_bytes);
}

test "the default limits are those of rpc 1.6" {
    const limits: Limits = .{};
    try testing.expect(validLimits(limits));
    try testing.expectEqual(@as(u32, 4096), limits.max_active_tasks);
    try testing.expectEqual(@as(u32, 256), limits.queue_capacity);
    try testing.expectEqual(@as(u32, 4352), limits.max_inflight);
    try testing.expectEqual(@as(usize, 1 << 20), limits.max_request_bytes);
    try testing.expectEqual(@as(usize, 1 << 20), limits.max_response_bytes);
    try testing.expectEqual(@as(usize, 8 << 20), limits.max_request_memory_bytes);
    try testing.expectEqual(@as(usize, 64 << 20), limits.max_live_request_memory_bytes);
    try testing.expectEqual(@as(u32, 64), limits.max_metadata_entries);
    try testing.expectEqual(@as(u32, 16 * 1024), limits.max_metadata_bytes);
    try testing.expectEqual(@as(u32, 32), limits.max_json_depth);
    try testing.expectEqual(@as(u32, 100_000), limits.max_container_items);
    try testing.expectEqual(@as(i64, 3000), limits.default_timeout.toMilliseconds());
    try testing.expectEqual(@as(i64, 300), limits.max_timeout.toSeconds());
    const options: Options = .{ .transport = undefined, .methods = &.{} };
    try testing.expectEqual(@as(i64, 10), options.shutdown_grace.toSeconds());
}

test "init refuses options that cannot work" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    const server_transport = memory.serverTransport();
    const good = [_]Method{methodOf("users", 1, "getUser")};

    const bad_methods = [_][]const Method{
        &.{},
        &.{methodOf("users", 0, "getUser")},
        &.{methodOf("users.x", 1, "getUser")},
        &.{methodOf("users", 1, "")},
        &.{methodOf(&@as([65]u8, @splat('s')), 1, "getUser")},
        &.{ methodOf("users", 1, "getUser"), methodOf("orders", 1, "list"), methodOf("users", 1, "getUser") },
        &.{.{ .route = good[0].route, .handler = no_handler, .timeout = .zero }},
        &.{.{ .route = good[0].route, .handler = no_handler, .timeout = .fromMilliseconds(-1) }},
    };
    for (bad_methods) |methods| {
        try testing.expectError(error.InvalidConfiguration, RawServer.init(testing.allocator, .{ .transport = server_transport, .methods = methods }));
    }

    const bad_limits = [_]Limits{
        .{ .max_active_tasks = 0 },
        .{ .queue_capacity = 0 },
        .{ .max_inflight = 0 },
        .{ .max_inflight = 4096 + 256 + 1 },
        .{ .max_request_bytes = 0 },
        .{ .max_request_bytes = 9 << 20 },
        .{ .max_request_memory_bytes = 65 << 20 },
        .{ .max_response_bytes = 1023 },
        .{ .max_metadata_entries = 0 },
        .{ .max_metadata_bytes = 1023 },
        .{ .max_json_depth = 0 },
        .{ .max_container_items = 0 },
        .{ .default_timeout = .zero },
        .{ .default_timeout = .fromSeconds(301) },
        .{ .max_timeout = .fromSeconds(-1) },
    };
    for (bad_limits) |limits| {
        try testing.expectError(error.InvalidConfiguration, RawServer.init(testing.allocator, .{ .transport = server_transport, .methods = &good, .limits = limits }));
    }
    try testing.expectError(error.InvalidConfiguration, RawServer.init(testing.allocator, .{
        .transport = server_transport,
        .methods = &good,
        .shutdown_grace = .fromMilliseconds(-1),
    }));

    // The smallest valid limits, and a grace of zero: cancel at once.
    var smallest: RawServer = try .init(testing.allocator, .{
        .transport = server_transport,
        .methods = &good,
        .shutdown_grace = .zero,
        .limits = .{
            .max_active_tasks = 1,
            .queue_capacity = 1,
            .max_inflight = 1,
            .max_request_bytes = 1,
            .max_response_bytes = 1024,
            .max_request_memory_bytes = 1,
            .max_live_request_memory_bytes = 1,
            .max_metadata_entries = 1,
            .max_metadata_bytes = 1024,
            .max_json_depth = 1,
            .max_container_items = 1,
            .default_timeout = .fromNanoseconds(1),
            .max_timeout = .fromNanoseconds(1),
        },
    });
    smallest.deinit(io);
}

fn initAndDeinit(gpa: std.mem.Allocator, server_transport: ServerTransport) !void {
    const methods = [_]Method{ methodOf("users", 1, "getUser"), methodOf("users", 1, "listUsers"), methodOf("orders", 7, "list") };
    var server: RawServer = try .init(gpa, .{ .transport = server_transport, .methods = &methods });
    server.deinit(testing.io);
}

test "init frees what it took when an allocation fails" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{memory.serverTransport()});
}
