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
const failures = @import("../failures.zig");
const ServerTransport = @import("../ServerTransport.zig");
const Context = @import("Context.zig").Context;
const Call = @import("Call.zig");

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
/// The memory all calls take now.
live_bytes: std.atomic.Value(usize) = .init(0),
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
    const server: *RawServer = @ptrCast(@alignCast(ptr));
    return server.admit(io, head, body_len);
}

/// Decides on a call before its body is read, in this order: the stop, the
/// route and codec, the metadata, the budget, a place, the memory. Never
/// waits and does no I/O.
fn admit(server: *RawServer, io: std.Io, head: *const transport.RequestHead, body_len: usize) transport.Dispatcher.Admission {
    if (server.grace_over.load(.acquire)) return .{ .rejected = failures.stopping };
    const index = server.lookup(head.route) orelse return .{ .rejected = failures.unknown_method };
    if (!std.mem.eql(u8, head.codec, "json")) return .{ .rejected = failures.unsupported_codec };
    const limits = server.limits;
    if (rules.checkRequestMetadata(head.metadata, .{ .max_entries = limits.max_metadata_entries, .max_bytes = limits.max_metadata_bytes })) |problem| {
        return .{ .rejected = switch (problem) {
            .invalid => failures.invalid_metadata,
            .too_large => failures.metadata_too_large,
        } };
    }
    const deadline = callDeadline(server.methods[index], limits, head) orelse return .{ .rejected = failures.invalid_timeout };
    if (deadline.remaining(now(io)).nanoseconds < std.time.ns_per_ms) return .{ .rejected = failures.deadline_exceeded };
    if (!server.takePlace()) return .{ .rejected = failures.overloaded };
    if (body_len > limits.max_request_bytes) {
        server.leave(io);
        return .{ .rejected = failures.request_too_large };
    }
    const call = Call.create(server, io, index, head, body_len, deadline) catch {
        server.leave(io);
        return .{ .rejected = failures.out_of_memory };
    };
    return .{ .accepted = call.incoming() };
}

/// The deadline of a call: from the moment the transport read its head, the
/// client's budget, but no more than the method's limit and `max_timeout`.
/// Null for a negative budget.
fn callDeadline(method: Method, limits: Limits, head: *const transport.RequestHead) ?core.Deadline {
    var budget = method.timeout orelse limits.default_timeout;
    if (head.timeout) |client| {
        if (client.nanoseconds < 0) return null;
        budget.nanoseconds = @min(budget.nanoseconds, client.nanoseconds);
    }
    budget.nanoseconds = @min(budget.nanoseconds, limits.max_timeout.nanoseconds);
    return .after(head.received_at, budget);
}

/// Takes a place for one more call, unless `max_inflight` calls are in
/// flight. Every admitted call holds a task or a place in the queue, so
/// `Incoming.start` always finds room.
fn takePlace(server: *RawServer) bool {
    var current = server.inflight.load(.monotonic);
    while (true) {
        if (current >= server.limits.max_inflight) return false;
        current = server.inflight.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic) orelse return true;
    }
}

/// A call has left: its place is free.
fn leave(server: *RawServer, io: std.Io) void {
    if (server.inflight.fetchSub(1, .acq_rel) == 1) server.idle.set(io);
}

/// Frees a call that has ended and frees its place.
pub fn retire(server: *RawServer, io: std.Io, call: *Call) void {
    // A Debug allocator may take a cancelable lock to capture a stack
    // trace, and would swallow a cancelation of the calling task.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    call.destroy();
    server.leave(io);
}

/// `Incoming.start`: runs the call or puts it in the queue.
pub fn schedule(server: *RawServer, io: std.Io, call: *Call) ?model.Failure {
    server.retire(io, call);
    return failures.no_task;
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
    steps: [8]Step = undefined,
    count: std.atomic.Value(usize) = .init(0),

    const Step = enum { start, drain, close };

    fn record(t: *FakeTransport, step: Step) void {
        const i = t.count.fetchAdd(1, .acq_rel);
        if (i < t.steps.len) t.steps[i] = step;
    }

    fn recorded(t: *FakeTransport) []const Step {
        return t.steps[0..@min(t.count.load(.acquire), t.steps.len)];
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{}, fake.recorded());
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{ .start, .drain, .close }, fake.recorded());
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{.start}, fake.recorded());
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{ .start, .drain, .close }, fake.recorded());
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{ .start, .drain, .close }, fake.recorded());
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
    try testing.expectEqualSlices(FakeTransport.Step, &.{ .start, .drain, .close }, fake.recorded());
}

const admission_methods = [_]Method{
    .{ .route = .{ .service = "users", .version = 1, .method = "getUser" }, .handler = no_handler, .timeout = .fromSeconds(2) },
    methodOf("users", 1, "listUsers"),
};

/// A server to start where it stays: once started, it must not move.
fn admissionServer(gpa: std.mem.Allocator, fake: *FakeTransport, limits: Limits) !RawServer {
    return .init(gpa, .{ .transport = .init(fake), .methods = &admission_methods, .limits = limits });
}

fn headOf(io: std.Io, method: []const u8) transport.RequestHead {
    return .{
        .route = .{ .service = "users", .version = 1, .method = method },
        .request_id = @splat(7),
        .codec = "json",
        .timeout = .fromSeconds(5),
        .received_at = now(io),
        .metadata = &.{},
    };
}

fn expectRefused(admission: transport.Dispatcher.Admission, expected: model.Failure) !void {
    switch (admission) {
        .accepted => |incoming| {
            incoming.abandon(testing.io);
            return error.TestUnexpectedResult;
        },
        .rejected => |failure| {
            try testing.expectEqual(expected.code, failure.code);
            try testing.expectEqualStrings(expected.app_code, failure.app_code);
            try testing.expectEqualStrings(expected.message, failure.message);
        },
    }
}

fn expectAdmitted(admission: transport.Dispatcher.Admission) !transport.Incoming {
    return switch (admission) {
        .accepted => |incoming| incoming,
        .rejected => error.TestUnexpectedResult,
    };
}

test "admission refuses by the route, the codec, the metadata and the budget, in this order" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try admissionServer(testing.allocator, &fake, .{});
    defer server.deinit(io);
    try server.start(io);
    const d = fake.dispatcher_value.?;

    var head = headOf(io, "deleteUser");
    try expectRefused(d.admit(io, &head, 2), failures.unknown_method);
    head.codec = "msgpack";
    try expectRefused(d.admit(io, &head, 2), failures.unknown_method);
    head = headOf(io, "get.User");
    try expectRefused(d.admit(io, &head, 2), failures.unknown_method);
    head = headOf(io, "getUser");
    head.route.version = 2;
    try expectRefused(d.admit(io, &head, 2), failures.unknown_method);

    head = headOf(io, "getUser");
    head.codec = "msgpack";
    head.metadata = &.{.{ .key = "X-Bad", .value = "1" }};
    try expectRefused(d.admit(io, &head, 2), failures.unsupported_codec);

    head = headOf(io, "getUser");
    const invalid = [_][]const model.Metadata.Entry{
        &.{.{ .key = "X-Bad", .value = "1" }},
        &.{.{ .key = "x-ok", .value = " padded" }},
        &.{.{ .key = "zefir-unknown", .value = "1" }},
        &.{ .{ .key = "authorization", .value = "Bearer a" }, .{ .key = "authorization", .value = "Bearer a" } },
        &.{.{ .key = "zefir-correlation-id", .value = &@as([129]u8, @splat('c')) }},
    };
    for (invalid) |metadata| {
        head.metadata = metadata;
        try expectRefused(d.admit(io, &head, 2), failures.invalid_metadata);
    }

    // Hostile sizes are refused before anything is allocated.
    const many = try testing.allocator.alloc(model.Metadata.Entry, 10_000);
    defer testing.allocator.free(many);
    @memset(many, .{ .key = "x-a", .value = "1" });
    const huge_value: [16 * 1024]u8 = @splat('v');
    const too_large = [_][]const model.Metadata.Entry{
        many[0..65],
        many,
        &.{.{ .key = "x-a", .value = &huge_value }},
        // Both too large and invalid: too large.
        &.{ .{ .key = "X-Bad", .value = "1" }, .{ .key = "x-a", .value = &huge_value } },
    };
    for (too_large) |metadata| {
        head.metadata = metadata;
        try expectRefused(d.admit(io, &head, 1 << 30), failures.metadata_too_large);
    }
    // Exactly at the limits: admitted.
    head.metadata = many[0..64];
    (try expectAdmitted(d.admit(io, &head, 0))).abandon(io);

    head = headOf(io, "getUser");
    head.timeout = .fromNanoseconds(-1);
    try expectRefused(d.admit(io, &head, 2), failures.invalid_timeout);
    head.timeout = .fromMicroseconds(500);
    try expectRefused(d.admit(io, &head, 2), failures.deadline_exceeded);
    head.timeout = .fromSeconds(5);
    head.received_at = now(io).subDuration(.fromSeconds(10));
    try expectRefused(d.admit(io, &head, 2), failures.deadline_exceeded);
    head.metadata = &.{.{ .key = "X-Bad", .value = "1" }};
    try expectRefused(d.admit(io, &head, 2), failures.invalid_metadata);

    try testing.expectEqual(@as(u32, 0), server.inflight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
}

test "admission holds a place per call and refuses one more" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try admissionServer(testing.allocator, &fake, .{ .max_active_tasks = 1, .queue_capacity = 1, .max_inflight = 2 });
    defer server.deinit(io);
    try server.start(io);
    const d = fake.dispatcher_value.?;
    const head = headOf(io, "getUser");
    // Calls left over by a failed check would hold the stop forever.
    var calls: [3]?transport.Incoming = @splat(null);
    defer for (calls) |call| if (call) |incoming| incoming.abandon(io);

    calls[0] = try expectAdmitted(d.admit(io, &head, 100));
    try testing.expectEqual(@as(usize, 100), calls[0].?.body().len);
    calls[1] = try expectAdmitted(d.admit(io, &head, 0));
    try testing.expectEqual(@as(usize, 0), calls[1].?.body().len);
    try testing.expectEqual(@as(u32, 2), server.inflight.load(.acquire));
    try expectRefused(d.admit(io, &head, 0), failures.overloaded);
    calls[0].?.abandon(io);
    calls[0] = null;
    calls[2] = try expectAdmitted(d.admit(io, &head, 0));
    for (&calls) |*call| if (call.*) |incoming| {
        incoming.abandon(io);
        call.* = null;
    };
    try testing.expectEqual(@as(u32, 0), server.inflight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
}

test "admission reserves the memory of a call before its body is read" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try admissionServer(testing.allocator, &fake, .{
        .max_request_bytes = 4096,
        .max_request_memory_bytes = 4096,
        .max_live_request_memory_bytes = 16 * 1024,
    });
    defer server.deinit(io);
    try server.start(io);
    const d = fake.dispatcher_value.?;
    const head = headOf(io, "getUser");

    // A claimed gigabyte costs nothing.
    try expectRefused(d.admit(io, &head, 1 << 30), failures.request_too_large);
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
    // The body fits max_request_bytes, but with the call's own memory not
    // max_request_memory_bytes.
    try expectRefused(d.admit(io, &head, 4096), failures.out_of_memory);

    // Calls until the memory of all calls runs out.
    var admitted: std.ArrayList(transport.Incoming) = .empty;
    defer admitted.deinit(testing.allocator);
    defer for (admitted.items) |incoming| incoming.abandon(io);
    while (true) {
        switch (d.admit(io, &head, 2048)) {
            .accepted => |incoming| try admitted.append(testing.allocator, incoming),
            .rejected => |failure| {
                try testing.expectEqualStrings(failures.out_of_memory.message, failure.message);
                break;
            },
        }
        try testing.expect(admitted.items.len < 16);
    }
    try testing.expect(admitted.items.len >= 2);
    try testing.expect(server.live_bytes.load(.acquire) <= 16 * 1024);
    try testing.expectEqual(@as(u32, @intCast(admitted.items.len)), server.inflight.load(.acquire));
    // A call that ends makes room for the next one.
    admitted.pop().?.abandon(io);
    try admitted.append(testing.allocator, try expectAdmitted(d.admit(io, &head, 2048)));
}

test "admission: a call the allocator cannot hold is refused, and nothing leaks" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var server = try admissionServer(failing.allocator(), &fake, .{});
    defer server.deinit(io);
    try server.start(io);
    const d = fake.dispatcher_value.?;
    var head = headOf(io, "getUser");
    head.metadata = &.{ .{ .key = "x-a", .value = "1" }, .{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" } };
    head.peer = .{ .name = "client" };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        failing.fail_index = failing.alloc_index + fail_index;
        switch (d.admit(io, &head, 16)) {
            .accepted => |incoming| {
                incoming.abandon(io);
                break;
            },
            .rejected => |failure| try testing.expectEqualStrings(failures.out_of_memory.message, failure.message),
        }
    }
    try testing.expect(fail_index > 0);
    try testing.expectEqual(@as(u32, 0), server.inflight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), server.live_bytes.load(.acquire));
}

test "admission copies the head: metadata without reserved keys, the peer, the deadline, the server's span" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try admissionServer(testing.allocator, &fake, .{ .default_timeout = .fromSeconds(4), .max_timeout = .fromSeconds(30) });
    defer server.deinit(io);
    try server.start(io);
    const d = fake.dispatcher_value.?;

    var traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01".*;
    var peer_name = "client-1".*;
    var metadata = [_]model.Metadata.Entry{
        .{ .key = "x-a", .value = "1" },
        .{ .key = "authorization", .value = "Bearer t" },
        .{ .key = "x-a", .value = "2" },
        .{ .key = "traceparent", .value = &traceparent },
        .{ .key = "tracestate", .value = "vendor=value" },
        .{ .key = "zefir-correlation-id", .value = "corr-1" },
    };
    var head = headOf(io, "getUser");
    head.metadata = &metadata;
    head.peer = .{ .name = &peer_name };
    const incoming = try expectAdmitted(d.admit(io, &head, 3));
    defer incoming.abandon(io);
    // The head is borrowed only during admit.
    traceparent[3] = 'f';
    peer_name[0] = 'X';
    metadata[0].value = "changed";

    const call: *Call = @ptrCast(@alignCast(incoming.ptr));
    const context = &call.context;
    try testing.expectEqualStrings("getUser", context.route.method);
    try testing.expectEqual(head.request_id, context.request_id);
    try testing.expectEqual(@as(usize, 2), context.metadata.len);
    try testing.expectEqualStrings("1", context.metadata[0].value);
    try testing.expectEqualStrings("2", context.metadata[1].value);
    try testing.expectEqualStrings("Bearer t", context.authorization.?);
    try testing.expectEqualStrings("corr-1", context.correlation_id.?);
    try testing.expectEqualStrings("client-1", context.peer.name);
    // The method's 2 s limit is shorter than the client's 5 s budget.
    try testing.expectEqual(head.received_at.addDuration(.fromSeconds(2)).nanoseconds, call.deadline.expires.nanoseconds);
    try testing.expectEqual(call.deadline, context.operation.deadline.?);
    try testing.expect(context.operation.cancellation == &call.token);

    const trace = context.operation.trace.?;
    try testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", &trace.trace_id.toHex());
    try testing.expect(!std.mem.eql(u8, "b7ad6b7169203331", &trace.span_id.toHex()));
    try testing.expect(!trace.is_remote and trace.flags.sampled);
    try testing.expectEqualStrings("value", trace.state.get("vendor").?);

    // A broken tracestate is dropped, the trace stays; a broken traceparent
    // leaves no trace.
    var second_metadata = [_]model.Metadata.Entry{
        .{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" },
        .{ .key = "tracestate", .value = "=broken" },
    };
    head.metadata = &second_metadata;
    const second = try expectAdmitted(d.admit(io, &head, 0));
    defer second.abandon(io);
    const second_call: *Call = @ptrCast(@alignCast(second.ptr));
    try testing.expect(second_call.context.operation.trace.?.state.isEmpty());
    second_metadata[0].value = "00-00000000000000000000000000000000-b7ad6b7169203331-01";
    const third = try expectAdmitted(d.admit(io, &head, 0));
    defer third.abandon(io);
    try testing.expectEqual(@as(?core.TraceContext, null), @as(*Call, @ptrCast(@alignCast(third.ptr))).context.operation.trace);

    // Deadlines: the client's budget when shorter, the default without a
    // method limit, never past max_timeout.
    head = headOf(io, "getUser");
    head.timeout = .fromSeconds(1);
    try expectDeadline(d, &head, .fromSeconds(1));
    head.timeout = null;
    try expectDeadline(d, &head, .fromSeconds(2));
    head = headOf(io, "listUsers");
    head.timeout = null;
    try expectDeadline(d, &head, .fromSeconds(4));
    head.timeout = .fromSeconds(60);
    try expectDeadline(d, &head, .fromSeconds(4));
}

fn expectDeadline(d: transport.Dispatcher, head: *const transport.RequestHead, budget: std.Io.Duration) !void {
    const incoming = try expectAdmitted(d.admit(testing.io, head, 0));
    defer incoming.abandon(testing.io);
    const call: *Call = @ptrCast(@alignCast(incoming.ptr));
    try testing.expectEqual(head.received_at.addDuration(budget).nanoseconds, call.deadline.expires.nanoseconds);
}

test "admission caps a method limit at max_timeout" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    const long = [_]Method{.{ .route = .{ .service = "users", .version = 1, .method = "getUser" }, .handler = no_handler, .timeout = .fromSeconds(60) }};
    var server: RawServer = try .init(testing.allocator, .{ .transport = .init(&fake), .methods = &long, .limits = .{ .max_timeout = .fromSeconds(10) } });
    defer server.deinit(io);
    try server.start(io);
    var head = headOf(io, "getUser");
    head.timeout = null;
    try expectDeadline(fake.dispatcher_value.?, &head, .fromSeconds(10));
}

test "admission refuses every call once the grace of a stop is over" {
    const io = testing.io;
    var fake: FakeTransport = .{};
    var server = try admissionServer(testing.allocator, &fake, .{});
    defer server.deinit(io);
    try server.start(io);
    server.endGrace();
    const head = headOf(io, "getUser");
    try expectRefused(fake.dispatcher_value.?.admit(io, &head, 0), failures.stopping);
}
