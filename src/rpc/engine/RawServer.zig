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
const waiting = @import("../wait.zig");
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

/// Guards the lifecycle fields below that are not atomic. Every section
/// under it is short and takes it with `lockUncancelable`.
mutex: std.Io.Mutex = .init,
/// Written under `mutex`; `state` reads it without.
state_value: std.atomic.Value(State) = .init(.configured),
/// `requestStop` or `Dispatcher.fail` came.
stop_requested: bool = false,
/// The transport did not start: the lifecycle task ends without a stop.
rollback: bool = false,
/// The first `Dispatcher.fail`.
fatal: ?transport.Dispatcher.FatalError = null,
/// The `std.Io` of `start`, for `Dispatcher.routeStats`, which gets none.
io: ?std.Io = null,
/// The task that leads the stop; `start` starts it, `deinit` joins it.
lifecycle: ?std.Io.Future(void) = null,
/// Set by `requestStop` and `Dispatcher.fail`: the lifecycle task begins
/// the stop.
stop_event: std.Io.Event = .unset,
/// Set once `start` has the transport's answer.
start_done: std.Io.Event = .unset,
/// Set when the server has stopped or the transport broke: `wait` returns.
wait_event: std.Io.Event = .unset,
/// Set when the server has stopped or the stop ran out of time: `shutdown`
/// returns.
shutdown_event: std.Io.Event = .unset,

/// Calls from admission until their end.
inflight: std.atomic.Value(u32) = .init(0),
/// Set when `inflight` drops to zero. Only the lifecycle task waits on it,
/// and resets it before it looks at `inflight`.
idle: std.Io.Event = .unset,
/// The shutdown grace is over: admission refuses calls, and calls that
/// have not started are refused.
grace_over: std.atomic.Value(bool) = .init(false),
/// The supervisors of the calls. Only the lifecycle task awaits it, once
/// the transport has closed and no call is left.
supervisors: std.Io.Group = .init,

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

/// The states of a server, in order. Later releases may not add values:
/// a `switch` over it needs no `else`.
pub const State = enum(u8) { configured, starting, running, draining, stopped };

/// The transport's errors from its `start`, a task that could not be
/// started, and a second `start`.
pub const StartError = ServerTransport.StartError || error{InvalidState};
/// The transport broke (`Dispatcher.fail`), the wait was canceled, or the
/// server never started (`InvalidState`).
pub const WaitError = transport.Dispatcher.FatalError || std.Io.Cancelable || error{InvalidState};
pub const ShutdownError = error{ShutdownTimeout} || WaitError;

/// How long the stop waits, once the transport has closed, for the calls it
/// canceled to end.
const cancel_budget: std.Io.Duration = .fromSeconds(1);

const log = std.log.scoped(.rpc);

/// Starts the transport. Returns once the server takes calls, or with the
/// transport's error (`AddressInUse`, the broker is unreachable), leaving
/// nothing running and the server `stopped`. A second `start` is
/// `error.InvalidState`. From here on the server stays at its address: the
/// transport holds a pointer to it.
pub fn start(server: *RawServer, io: std.Io) StartError!void {
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        if (server.state_value.load(.monotonic) != .configured) return error.InvalidState;
        server.state_value.store(.starting, .release);
        server.io = io;
    }
    // The stop runs in a task of its own: `requestStop` only wakes it, and
    // `wait` may be canceled. It starts first, so that a stop requested
    // while the transport starts is not lost.
    server.lifecycle = io.concurrent(runLifecycle, .{ server, io }) catch |err| {
        server.markStopped(io);
        return err;
    };
    server.server_transport.start(io, server.dispatcher()) catch |err| {
        {
            server.mutex.lockUncancelable(io);
            defer server.mutex.unlock(io);
            server.rollback = true;
        }
        server.start_done.set(io);
        server.stop_event.set(io);
        server.joinLifecycle(io);
        server.markStopped(io);
        return err;
    };
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        // A stop requested while the transport started: straight to draining.
        server.state_value.store(if (server.stop_requested) .draining else .running, .release);
    }
    server.start_done.set(io);
}

/// Waits until the server has stopped. Returns at once with the error when
/// the transport broke (`Dispatcher.fail`): the server then stops by
/// itself. `error.InvalidState` before `start`. Canceling the wait does not
/// stop the server.
pub fn wait(server: *RawServer, io: std.Io) WaitError!void {
    if (server.state_value.load(.acquire) == .configured) return error.InvalidState;
    try server.wait_event.wait(io);
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    if (server.fatal) |err| return err;
}

/// `start` and `wait`: for a service that runs one server until it stops.
pub fn run(server: *RawServer, io: std.Io) (StartError || WaitError)!void {
    try server.start(io);
    return server.wait(io);
}

/// Begins a graceful stop. From any task, also from a handler; never
/// waits; a second call does nothing. The server drains its transport,
/// lets the calls in flight run for `shutdown_grace`, cancels the rest,
/// closes the transport and stops.
pub fn requestStop(server: *RawServer, io: std.Io) void {
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    server.stopLocked(io);
}

/// `requestStop` and a wait for the stop. `error.ShutdownTimeout` when
/// handlers did not end within `shutdown_grace` and one second more after
/// they were canceled: the server stays in `draining`. Treat it as fatal
/// and end the process; `deinit` would wait for such handlers without a
/// limit.
pub fn shutdown(server: *RawServer, io: std.Io) ShutdownError!void {
    server.requestStop(io);
    try server.shutdown_event.wait(io);
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    if (server.state_value.load(.monotonic) != .stopped) return error.ShutdownTimeout;
    if (server.fatal) |err| return err;
}

/// Running and the transport's own condition holds. Thread-safe; for
/// health checks.
pub fn isReady(server: *const RawServer) bool {
    return server.state() == .running and server.server_transport.isReady();
}

/// The state now. Thread-safe; for health checks.
pub fn state(server: *const RawServer) State {
    return server.state_value.load(.acquire);
}

/// Frees the server. A server that has not stopped is stopped first, and
/// `deinit` waits for it without a limit.
pub fn deinit(server: *RawServer, io: std.Io) void {
    server.requestStop(io);
    server.joinLifecycle(io);
    server.arena.deinit();
    server.* = undefined;
}

/// Under `mutex`.
fn stopLocked(server: *RawServer, io: std.Io) void {
    switch (server.state_value.load(.monotonic)) {
        .configured => {
            server.state_value.store(.stopped, .release);
            server.wait_event.set(io);
            server.shutdown_event.set(io);
        },
        .starting, .running => |current| {
            // While starting, `start` moves on to draining itself.
            if (current == .running) server.state_value.store(.draining, .release);
            server.stop_requested = true;
            server.stop_event.set(io);
        },
        .draining, .stopped => {},
    }
}

fn markStopped(server: *RawServer, io: std.Io) void {
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        server.state_value.store(.stopped, .release);
    }
    server.wait_event.set(io);
    server.shutdown_event.set(io);
}

fn joinLifecycle(server: *RawServer, io: std.Io) void {
    const future = if (server.lifecycle) |*future| future else return;
    // Waiting for the stop is no cancelation point here: a cancelation
    // request stays for the caller's next one.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    future.await(io);
    server.lifecycle = null;
}

/// The lifecycle task: waits for a stop and leads it.
fn runLifecycle(server: *RawServer, io: std.Io) void {
    // Nothing cancels this task, and its waits are no cancelation points.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server.stop_event.waitUncancelable(io);
    server.start_done.waitUncancelable(io);
    if (server.rollback) return;

    server.server_transport.drain(io);
    _ = server.waitIdle(io, .after(now(io), server.shutdown_grace));
    server.endGrace();
    server.server_transport.close(io);
    if (!server.waitIdle(io, .after(now(io), cancel_budget))) {
        // Handlers that ignore cancelation: `shutdown` returns
        // `ShutdownTimeout` while the server stays in draining, and the
        // stop goes on without a limit.
        server.shutdown_event.set(io);
        _ = server.waitIdle(io, null);
    }
    // No call is left and the transport has closed, so no supervisor
    // starts any more.
    server.supervisors.cancel(io);
    server.markStopped(io);
}

/// Waits until no call is in flight or `deadline` passes; true when no call
/// is. Only the lifecycle task calls it.
fn waitIdle(server: *RawServer, io: std.Io, deadline: ?core.Deadline) bool {
    while (true) {
        server.idle.reset();
        if (server.inflight.load(.acquire) == 0) return true;
        if (deadline) |d| {
            waiting.untilSet(&server.idle, io, d) catch |err| switch (err) {
                error.Timeout => return server.inflight.load(.acquire) == 0,
                // The lifecycle task waits with cancelation blocked.
                error.Canceled => unreachable,
            };
        } else server.idle.waitUncancelable(io);
    }
}

/// The grace is over: admission refuses new calls.
fn endGrace(server: *RawServer) void {
    server.grace_over.store(true, .release);
}

fn dispatcher(server: *RawServer) transport.Dispatcher {
    return .{ .ptr = server, .vtable = &dispatcher_vtable };
}

const dispatcher_vtable: transport.Dispatcher.VTable = .{
    .service = serviceFn,
    .admit = admitFn,
    .fail = failFn,
    .routeStats = routeStatsFn,
};

fn serviceFn(ptr: *anyopaque) *const transport.Dispatcher.Service {
    const server: *RawServer = @ptrCast(@alignCast(ptr));
    return &server.service_info;
}

fn admitFn(ptr: *anyopaque, io: std.Io, head: *const transport.RequestHead, body_len: usize) transport.Dispatcher.Admission {
    _ = ptr;
    _ = io;
    _ = head;
    _ = body_len;
    return .{ .rejected = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" } };
}

fn failFn(ptr: *anyopaque, io: std.Io, err: transport.Dispatcher.FatalError, diagnostics: ?*const transport.Diagnostics) void {
    const server: *RawServer = @ptrCast(@alignCast(ptr));
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        if (server.fatal != null) return;
        server.fatal = err;
        server.stopLocked(io);
    }
    server.wait_event.set(io);
    // Diagnostics hold no metadata values, bodies or credentials.
    const message = if (diagnostics) |d| d.message() else "";
    log.warn("the server transport broke: {t}{s}{s}", .{ err, if (message.len > 0) ": " else "", message });
}

fn routeStatsFn(ptr: *anyopaque, route_index: usize) transport.Dispatcher.RouteStats {
    _ = ptr;
    _ = route_index;
    return .{ .requests = 0, .errors = 0, .processing_time = .zero };
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
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

/// A server transport that records what the engine calls, for the tests of
/// the lifecycle.
const FakeTransport = struct {
    /// The error of the next `start`.
    start_error: ?ServerTransport.StartError = null,
    /// `start` waits until `release_start` is set.
    hold_start: bool = false,
    start_entered: std.Io.Event = .unset,
    release_start: std.Io.Event = .unset,
    ready: std.atomic.Value(bool) = .init(true),
    dispatcher_value: ?transport.Dispatcher = null,
    calls: [8]Call = undefined,
    count: std.atomic.Value(usize) = .init(0),

    const Call = enum { start, drain, close };

    fn record(t: *FakeTransport, call: Call) void {
        const i = t.count.fetchAdd(1, .acq_rel);
        if (i < t.calls.len) t.calls[i] = call;
    }

    fn recorded(t: *FakeTransport) []const Call {
        return t.calls[0..@min(t.count.load(.acquire), t.calls.len)];
    }

    pub fn start(t: *FakeTransport, io: std.Io, d: transport.Dispatcher) ServerTransport.StartError!void {
        t.record(.start);
        if (t.hold_start) {
            t.start_entered.set(io);
            t.release_start.waitUncancelable(io);
        }
        if (t.start_error) |err| return err;
        t.dispatcher_value = d;
    }

    pub fn drain(t: *FakeTransport, io: std.Io) void {
        _ = io;
        t.record(.drain);
    }

    pub fn close(t: *FakeTransport, io: std.Io) void {
        _ = io;
        t.record(.close);
    }

    pub fn info(t: *FakeTransport) transport.Info {
        _ = t;
        return .{ .name = "fake" };
    }

    pub fn isReady(t: *FakeTransport) bool {
        return t.ready.load(.acquire);
    }
};

const one_method = [_]Method{methodOf("users", 1, "getUser")};

fn fakeServer(fake: *FakeTransport) !RawServer {
    return .init(testing.allocator, .{ .transport = .init(fake), .methods = &one_method, .shutdown_grace = .fromMilliseconds(50) });
}

test "lifecycle: a server that never starts" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    try testing.expectEqual(State.configured, server.state());
    try testing.expect(!server.isReady());
    try testing.expectError(error.InvalidState, server.wait(io));

    // requestStop before start: stopped for good.
    server.requestStop(io);
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.InvalidState, server.start(io));
    try server.wait(io);
    try server.shutdown(io);
    server.requestStop(io);
    try testing.expectEqualSlices(FakeTransport.Call, &.{}, fake.recorded());
}

test "lifecycle: start, requestStop and wait drain the transport, then close it" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    try server.start(io);
    try testing.expectEqual(State.running, server.state());
    try testing.expect(server.isReady());
    fake.ready.store(false, .release);
    try testing.expect(!server.isReady());
    fake.ready.store(true, .release);
    try testing.expectError(error.InvalidState, server.start(io));
    try testing.expectEqualStrings("users", fake.dispatcher_value.?.service().routes[0].service);

    server.requestStop(io);
    try testing.expect(server.state() == .draining or server.state() == .stopped);
    try testing.expect(!server.isReady());
    try server.wait(io);
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqualSlices(FakeTransport.Call, &.{ .start, .drain, .close }, fake.recorded());
    try testing.expectError(error.InvalidState, server.start(io));
    server.requestStop(io);
    try server.wait(io);
    try server.shutdown(io);
}

test "lifecycle: a transport that does not start leaves the server stopped" {
    const io = testing.io;
    var fake: FakeTransport = .{ .start_error = error.AddressInUse };
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    try testing.expectError(error.AddressInUse, server.start(io));
    try testing.expectEqual(State.stopped, server.state());
    try server.wait(io);
    try testing.expectError(error.InvalidState, server.start(io));
    // Neither drain nor close: the transport left nothing running.
    try testing.expectEqualSlices(FakeTransport.Call, &.{.start}, fake.recorded());
}

fn startTask(server: *RawServer, io: std.Io) StartError!void {
    return server.start(io);
}

test "lifecycle: requestStop while the transport starts: start ends, the server drains at once" {
    const io = testing.io;
    var fake: FakeTransport = .{ .hold_start = true };
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    var starter = try io.concurrent(startTask, .{ &server, io });
    // A failed check below must not leave the start waiting.
    defer fake.release_start.set(io);
    fake.start_entered.waitUncancelable(io);
    try testing.expectEqual(State.starting, server.state());
    server.requestStop(io);
    try testing.expectEqual(State.starting, server.state());
    fake.release_start.set(io);
    try starter.await(io);
    try testing.expect(server.state() != .running);
    try server.wait(io);
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectEqualSlices(FakeTransport.Call, &.{ .start, .drain, .close }, fake.recorded());
}

test "lifecycle: a broken transport wakes wait with its error, and the server stops by itself" {
    const io = testing.io;
    // The engine logs the broken transport as a warning, expected here.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    try server.start(io);
    var diagnostics: transport.Diagnostics = .{};
    diagnostics.set(.connect, error.ConnectionRefused, "port 4222 gone", .{});
    fake.dispatcher_value.?.fail(io, error.Unavailable, &diagnostics);
    // A second fail does nothing.
    fake.dispatcher_value.?.fail(io, error.AccessDenied, null);
    try testing.expectError(error.Unavailable, server.wait(io));
    try testing.expect(server.state() == .draining or server.state() == .stopped);
    try testing.expectError(error.Unavailable, server.shutdown(io));
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.Unavailable, server.wait(io));
    try testing.expectEqualSlices(FakeTransport.Call, &.{ .start, .drain, .close }, fake.recorded());
}

fn runTask(server: *RawServer, io: std.Io) (StartError || WaitError)!void {
    return server.run(io);
}

fn waitTask(server: *RawServer, io: std.Io) WaitError!void {
    return server.wait(io);
}

test "lifecycle: run returns after requestStop from another task" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    var runner = try io.concurrent(runTask, .{ &server, io });
    defer server.requestStop(io);
    while (server.state() != .running) try io.sleep(.fromMilliseconds(1), .awake);
    server.requestStop(io);
    try runner.await(io);
    try testing.expectEqual(State.stopped, server.state());
}

test "lifecycle: canceling wait does not stop the server" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    defer server.deinit(io);
    try server.start(io);
    var waiter = try io.concurrent(waitTask, .{ &server, io });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, waiter.cancel(io));
    try testing.expectEqual(State.running, server.state());
    try server.shutdown(io);
    try testing.expectEqual(State.stopped, server.state());
}

test "lifecycle: deinit stops a running server" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try fakeServer(&fake);
    try server.start(io);
    server.deinit(io);
    try testing.expectEqualSlices(FakeTransport.Call, &.{ .start, .drain, .close }, fake.recorded());
}
