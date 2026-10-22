//! `rpc.Server`: the server of an application. It serves the handlers of
//! one or more contracts on a transport; requests and responses are the
//! contracts' types, sent as JSON.
//!
//! ```zig
//! var users: UserHandler = .init(&repo);
//! var server = try rpc.Server.init(gpa, .{
//!     .handlers = .{ &users, &orders },     // pointers to handlers, at least one
//!     // .authenticator = &auth,            // checks the credentials of calls
//!     // .middleware = .{ mw.logCalls, &limiter }, // around every call
//! }, .{
//!     .transport = bus.serverTransport(),  // rpc_nats.Transport; in tests the memory transport
//!     // .limits = .{ .max_active_tasks = 1024 },
//!     // .shutdown_grace = .fromSeconds(10),
//! });
//! defer server.deinit(io);
//! try server.run(io); // start and wait; server.requestStop(io) from any task stops it
//! ```
//!
//! The compiler checks every handler where it is passed to `init`: that it
//! declares `pub const rpc_handler = rpc.implement(Api, ...)`, that it has
//! a `pub fn` of the contract's signature for each method of the contract,
//! that no two handlers serve one route, and that a method which requires
//! an identity has an authenticator. A mistake stops the build with a
//! message that names the handler and what to write. Zig checks only what
//! is used, so a service keeps a test that builds its server with the
//! memory transport: then `zig build test` runs the checks too.
//!
//! The path of a call through a method: the engine authenticates it and
//! runs the middleware; the body is decoded as the method's request and
//! checked against its `field_rules`; the method runs; its response is
//! checked against its rules and encoded. A body that does not decode or a
//! request against its rules ends the call with `invalid_argument` and
//! `rpc.invalid_request`; a response against the server's own contract
//! with `internal` and `rpc.invalid_response`. The errors of the method go
//! on as they are: the contract's `.errors`, then the framework's names
//! (`error.Unavailable` → `unavailable`, ...), else `internal`.
//!
//! The strings and slices of a decoded request point into the memory of
//! its call, the body and the call's arena, and live only until the call
//! ends with its response. A handler that keeps one longer, such as a key
//! in a map of its own, copies it first: `gpa.dupe(u8, req.name)`.
//!
//! The handlers, the authenticator and the objects of middleware are
//! borrowed: their owner keeps them alive until `deinit`. Each serves all
//! calls at once, so its state is guarded with `std.Io` primitives. Under
//! `rpc.Server` works the engine, `rpc.RawServer`, with the same lifecycle
//! and the same guarantees.

const std = @import("std");
const RawServer = @import("../engine/RawServer.zig");
const Authenticator = @import("../auth.zig").Authenticator;
const Middleware = @import("../middleware.zig").Middleware;
const MiddlewareFn = @import("../middleware.zig").MiddlewareFn;
const Next = @import("../middleware.zig").Next;
const Context = @import("../engine/Context.zig").Context;
const handlers = @import("handlers.zig");
const method = @import("method.zig");
const ServerTransport = @import("../ServerTransport.zig");

const Server = @This();

/// The engine that runs the calls. `init` builds its methods from the
/// handlers.
engine: RawServer,

/// `InvalidConfiguration`: limits that are zero or contradict each other,
/// or a negative shutdown grace (see `rpc.RawServer.InitError`); the
/// handlers are checked when the server is built.
pub const InitError = RawServer.InitError;
pub const State = RawServer.State;
pub const StartError = RawServer.StartError;
pub const WaitError = RawServer.WaitError;
pub const ShutdownError = RawServer.ShutdownError;

/// The settings of a server, the second argument of `init`.
pub const Options = struct {
    /// The server side of a transport, such as `bus.serverTransport()`;
    /// its owner keeps it until after the server's `deinit`.
    transport: ServerTransport,
    /// The limits of the engine, such as `.{ .max_active_tasks = 1024 }`.
    /// The limit of a call is the `timeout_ms` of its method (3 seconds by
    /// default), cut to `max_timeout`. `default_timeout` is for methods of
    /// the engine without a limit of their own and does not apply here:
    /// `init` lowers it to `max_timeout` when it is above.
    limits: RawServer.Limits = .{},
    /// How long calls in flight may run after `requestStop`.
    shutdown_grace: std.Io.Duration = .fromSeconds(10),
};

/// Builds a server from its parts and its options.
///
/// `parts` is a struct literal of what the compiler checks by type:
///
/// - `.handlers`: a tuple of pointers to handlers, at least one: `.{ &users, &orders }`;
/// - `.authenticator` (optional): a pointer to an object with
///   `pub fn authenticate(self: *@This(), ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView`;
/// - `.middleware` (optional): the links of the server's level, around
///   every call, in order: middleware functions and pointers to objects
///   with `run`, such as `.{ mw.logCalls, &limiter }`. The links of a
///   handler and of a method come from its `rpc_handler`: functions, and
///   names of the handler's fields that hold an object or point to one
///   (`.fraud` is `self.fraud`, read on every call). A call runs the
///   server's links, then the handler's, then the method's, each level
///   left to right, and unwinds them in reverse.
///
/// `options` are its settings, `Options`.
///
/// No I/O and no tasks; memory only for the tables of the engine.
pub fn init(gpa: std.mem.Allocator, parts: anytype, options: Options) InitError!Server {
    // The loops below unroll once per method and link.
    @setEvalBranchQuota(handlers.eval_quota);
    const P = @TypeOf(parts);
    comptime check(P);
    const Handlers = @FieldType(P, "handlers");
    // The engine copies these lists; they live only until it has.
    const methods = try gpa.alloc(RawServer.Method, comptime methodCount(Handlers));
    defer gpa.free(methods);
    const links = try gpa.alloc(Middleware, comptime linkCount(Handlers));
    defer gpa.free(links);
    var next_method: usize = 0;
    var next_link: usize = 0;
    inline for (@typeInfo(Handlers).@"struct".field_names) |field| {
        const handler = @field(parts.handlers, field);
        const T = @typeInfo(@TypeOf(handler)).pointer.child;
        const Impl = T.rpc_handler;
        const C = @TypeOf(Impl.api);
        inline for (@typeInfo(C).@"struct".field_names) |name| {
            const M = @FieldType(C, name);
            const settings = comptime Impl.settingsOf(name);
            // The handler's links, then the method's.
            const first = next_link;
            inline for (.{ Impl.middleware, comptime handlers.methodLinks(Impl, name) }) |level| {
                inline for (@typeInfo(@TypeOf(level)).@"struct".field_names) |item| {
                    links[next_link] = handlerLink(T, handler, @field(level, item));
                    next_link += 1;
                }
            }
            methods[next_method] = .{
                .route = M.route,
                .handler = .{ .ptr = handler, .handle = method.Wrapper(T, M).handle },
                .middleware = links[first..next_link],
                .auth = settings.auth,
                .timeout = .fromMilliseconds(settings.timeout_ms),
                .map_error = &M.contract.mapError,
            };
            next_method += 1;
        }
    }
    const ServerLinks = if (@hasField(P, "middleware")) @FieldType(P, "middleware") else @TypeOf(.{});
    var server_links: [@typeInfo(ServerLinks).@"struct".field_names.len]Middleware = undefined;
    if (@hasField(P, "middleware")) {
        inline for (@typeInfo(ServerLinks).@"struct".field_names, &server_links) |item, *link| link.* = .of(@field(parts.middleware, item));
    }
    // No method of rpc.Server uses the default, and the engine refuses one
    // over the maximum.
    var limits = options.limits;
    limits.default_timeout.nanoseconds = @min(limits.default_timeout.nanoseconds, limits.max_timeout.nanoseconds);
    var engine_options: RawServer.Options = .{
        .transport = options.transport,
        .methods = methods,
        .middleware = &server_links,
        .limits = limits,
        .shutdown_grace = options.shutdown_grace,
    };
    if (comptime handlers.hasAuthenticator(P)) engine_options.authenticator = Authenticator.init(parts.authenticator);
    return .{ .engine = try .init(gpa, engine_options) };
}

/// The link of `item` on the level of a handler or of one method: a
/// middleware function, or `.name` of a field of the handler that holds an
/// object or points to one. The link reads the field on every call, so the
/// handler may set it after `init`.
fn handlerLink(comptime T: type, handler: *T, comptime item: anytype) Middleware {
    if (@TypeOf(item) == MiddlewareFn) return .of(item);
    return .{ .ptr = handler, .run = struct {
        fn run(ptr: ?*anyopaque, ctx: *Context, next: *Next) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ptr.?));
            return @field(self, @tagName(item)).run(ctx, next);
        }
    }.run };
}

fn check(comptime P: type) void {
    if (handlers.partsProblem(P)) |message| @compileError(message);
}

/// The methods of all contracts of the handlers of type `Handlers`.
fn methodCount(comptime Handlers: type) usize {
    @setEvalBranchQuota(handlers.eval_quota);
    var count: usize = 0;
    for (@typeInfo(Handlers).@"struct".field_types) |Pointer| {
        const T = @typeInfo(Pointer).pointer.child;
        count += @typeInfo(@TypeOf(T.rpc_handler.api)).@"struct".field_names.len;
    }
    return count;
}

/// The links of all methods of the handlers of type `Handlers`: each
/// method has those of its handler and its own.
fn linkCount(comptime Handlers: type) usize {
    @setEvalBranchQuota(handlers.eval_quota);
    var count: usize = 0;
    for (@typeInfo(Handlers).@"struct".field_types) |Pointer| {
        const Impl = @typeInfo(Pointer).pointer.child.rpc_handler;
        const handler_links = @typeInfo(@TypeOf(Impl.middleware)).@"struct".field_names.len;
        for (@typeInfo(@TypeOf(Impl.api)).@"struct".field_names) |name| {
            count += handler_links + @typeInfo(@TypeOf(handlers.methodLinks(Impl, name))).@"struct".field_names.len;
        }
    }
    return count;
}

/// Starts the transport. Returns once the server takes calls, or with the
/// transport's error, leaving the server `stopped`. From here on the
/// server stays at its address.
pub fn start(server: *Server, io: std.Io) StartError!void {
    return server.engine.start(io);
}

/// Waits until the server has stopped; at once with the error when the
/// transport broke. Canceling the wait does not stop the server.
pub fn wait(server: *Server, io: std.Io) WaitError!void {
    return server.engine.wait(io);
}

/// `start` and `wait`: for a service that runs one server until it stops.
pub fn run(server: *Server, io: std.Io) (StartError || WaitError)!void {
    return server.engine.run(io);
}

/// Begins a graceful stop. From any task, also from a handler; never
/// waits.
pub fn requestStop(server: *Server, io: std.Io) void {
    server.engine.requestStop(io);
}

/// `requestStop` and a wait for the stop, which returns 250 ms before
/// `deadline` at the latest: the deadline cuts `shutdown_grace`, so that
/// the calls it cancels have time to end (see `rpc.RawServer.shutdown`).
/// `error.ShutdownTimeout` when the server has not stopped by then: the
/// server stays in `draining`. Treat it as fatal and end the process;
/// `deinit` would wait for such handlers without a limit.
pub fn shutdown(server: *Server, io: std.Io, deadline: std.Io.Clock.Timestamp) ShutdownError!void {
    return server.engine.shutdown(io, deadline);
}

/// Running and the transport's own condition holds. Thread-safe; for
/// health checks.
pub fn isReady(server: *const Server) bool {
    return server.engine.isReady();
}

/// The state now. Thread-safe; for health checks.
pub fn state(server: *const Server) State {
    return server.engine.state();
}

/// Stops the server if it runs, waits for the stop and frees the tables.
/// The wait has no limit: a handler that ignores cancelation keeps
/// `deinit` waiting, so after `error.ShutdownTimeout` end the process
/// instead. No other task may still be in `wait`, `run` or `shutdown`.
pub fn deinit(server: *Server, io: std.Io) void {
    server.engine.deinit(io);
    server.* = undefined;
}
