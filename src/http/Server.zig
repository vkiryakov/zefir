//! `http.Server`: one type for every application.
//! `init` takes the parts of a server, which the compiler checks by type,
//! and its `Options`. It does the compile-time work over the parts
//! (plan.zig): it reads the routes of the controllers, checks them and
//! builds the router's trie; at run time it copies the server's prefix and
//! keeps the table of routes.
//!
//! ```zig
//! var server = try http.Server.init(gpa, .{
//!     .controllers = .{ &todos_v1, &health },
//! }, .{
//!     .listen = .{ .port = 8080 },
//!     .prefix = "/api", // only for controllers; may come from the config
//! });
//! defer server.deinit(io);
//! try server.run(io);
//! ```
//!
//! The compiler checks every controller where it is passed to `init`: a
//! pointer to a mutable instance, `pub const http_routes =
//! http.routes(.{ ... })`, a `pub fn` of the right form for each route,
//! patterns that parse and no two routes of one method on one path. Zig
//! checks only what is used, so an application keeps a test that builds
//! its server: then `zig build test` runs the checks too.
//!
//! The lifecycle is that of `rpc.Server`: `start`, `wait`, `run`,
//! `requestStop`, `shutdown`, `isReady`, `state`, `deinit`, with the states
//! configured → starting → running → draining → stopped. From `start` on
//! the server stays where it is: its backend holds a pointer to it.
const std = @import("std");
const core = @import("core");
const Backend = @import("Backend.zig");
const NativeBackend = @import("native/Backend.zig");
const Context = @import("Context.zig");
const dto = @import("dto.zig");
const flow = @import("flow.zig");
const mw = @import("middleware.zig");
const plan = @import("plan.zig");
const proxies = @import("proxies.zig");
const route_decls = @import("routes.zig");
const routing = @import("router.zig");
const sse = @import("sse.zig");
const static_files = @import("static.zig");
const waiting = @import("wait.zig");
const path_rules = @import("path.zig");

const Server = @This();
const Duration = std.Io.Duration;
const log = std.log.scoped(.http);

/// Internal to the server: its tables, which `init` builds, and the state
/// of its lifecycle.
internal: Internal,

pub const Internal = struct {
    gpa: std.mem.Allocator,
    /// Where requests come from: the backend of `.listen`.
    backend: Backend,
    /// The native backend the server made for `.listen = .port` or
    /// `.native`; `deinit` frees it last. Null for a backend of your own.
    native: ?*NativeBackend,
    /// The server's prefix, copied: it may come from the config.
    prefix: []const u8,
    /// The routes of all controllers, in the order of `.controllers`, each in
    /// the order of its `.methods`; `router` gives indices into it.
    routes: []Route,
    router: routing.Router,
    /// The links of every chain: the server's middleware, then the own
    /// middleware of each route, in the order of `routes`. `middleware` and
    /// the `links` of each route are parts of it.
    links: []mw.Link,
    /// The server's middleware: every request runs it before its route is
    /// applied.
    middleware: []const mw.Link,
    /// What the server keeps of its `Options`: all of them but `.listen`,
    /// `.prefix` and `.static`, with the list of `.trusted_proxies`
    /// copied. The prefix and the mounts are copied apart and the backend
    /// is `backend`, so nothing here points into the caller's memory.
    settings: Settings,
    /// `.trusted_proxies`, its list parsed.
    trust: proxies.Trust,
    /// What the routes need of the backend; `start` checks it.
    needs: Needs,
    /// `.error_handler`, borrowed, or the default one.
    error_handler: flow.ErrorHandler,
    /// The mounts of `.static`, copied; `start` opens their roots, `deinit`
    /// closes them.
    mounts: []static_files.Mount,

    /// Guards the lifecycle fields below that are not atomic; every section
    /// under it is short.
    mutex: std.Io.Mutex = .init,
    /// Written under `mutex`; `state` reads it without.
    state_value: std.atomic.Value(State) = .init(.configured),
    /// `requestStop` came.
    stop_requested: bool = false,
    /// The backend did not start: the lifecycle task ends without a stop.
    rollback: bool = false,
    /// The task that leads the stop; `start` starts it, `deinit` joins it.
    lifecycle: ?std.Io.Future(void) = null,
    /// Set by `requestStop`: the lifecycle task begins the stop.
    stop_event: std.Io.Event = .unset,
    /// Set once `start` has the backend's answer.
    start_done: std.Io.Event = .unset,
    /// Set when the server has stopped: `wait` returns.
    wait_event: std.Io.Event = .unset,
    /// Set when the server has stopped: `shutdown` returns.
    shutdown_event: std.Io.Event = .unset,
    /// The earliest deadline a `shutdown` gave, on the awake clock; under
    /// `mutex`. It ends the grace of the stop in time.
    deadline: ?core.Deadline = null,
    /// The error of a backend that broke, the first (`Backend.Handler.fail`);
    /// under `mutex`. `wait` and `shutdown` return it.
    fatal: ?Backend.FatalError = null,
    /// The requests at work, as `.max_in_flight` counts them: `serve` takes a
    /// place before a request runs and gives it back at its end.
    in_flight: std.atomic.Value(u32) = .init(0),
    /// Set when `in_flight` or `streams` drops to zero, and when a
    /// `shutdown` brings a deadline. Only the lifecycle task waits on it,
    /// and resets it before it looks at the counts and the deadline.
    idle: std.Io.Event = .unset,
    /// The SSE streams open now, as `.max_streams` counts them: `subscribe`
    /// takes a place, the end of the stream gives it back.
    streams: std.atomic.Value(u32) = .init(0),
    /// The streams that run, for the stop to close them at once; under
    /// `streams_mutex`, which is never held across I/O.
    stream_list: std.DoublyLinkedList = .{},
    streams_mutex: std.Io.Mutex = .init,
    /// The stop has closed the streams: one that begins now ends at once.
    streams_closed: bool = false,
};

/// The states of a server, in order.
pub const State = enum(u8) { configured, starting, running, draining, stopped };

/// `InvalidConfiguration`: a `.prefix` that is not empty and not such as
/// "/api" or "/api/v2" (segments of visible ASCII, without `%`, `?`, `#`,
/// `{` and `}`, no empty or dot segments, no trailing slash); a
/// `.max_in_flight`, `.max_streams` or `.json.max_depth` of 0; a negative
/// duration, or a `.request_timeout` of 0; an entry of a `.trusted_proxies`
/// list that is neither a CIDR block nor an address; a `.static` mount
/// whose path is not "/" or such as a prefix, two mounts on one path, an
/// empty root, an index file that is not one name, a `spa_fallback` with a
/// segment that a request could not name (a hidden one, say), or a
/// `cache_control` with CR, LF or NUL; options of `.listen = .native` that
/// `http.native.Backend.init` refuses.
pub const InitError = error{ InvalidConfiguration, OutOfMemory };
/// The backend's errors from its `start`, a task the runtime did not give,
/// a second `start` (`InvalidState`), a route that needs what the backend
/// cannot do (`UnsupportedByBackend`: an SSE route needs `flush`, static
/// files `streaming_response`), and the root of a `.static` mount that is
/// missing, is not a directory or does not open (`InvalidStaticRoot`,
/// logged with the mount, the path and the error of the system).
pub const StartError = Backend.StartError || error{ InvalidState, UnsupportedByBackend, InvalidStaticRoot };
/// The backend broke (`Unavailable`: it takes no new requests;
/// `Unexpected`), and the server stops by itself; the wait was canceled;
/// or the server never started (`InvalidState`).
pub const WaitError = Backend.FatalError || error{InvalidState} || std.Io.Cancelable;
pub const ShutdownError = error{ShutdownTimeout} || WaitError;

/// From whom to believe `X-Forwarded-For` and `Forwarded`: everybody,
/// loopback and private networks, nobody, or a list of CIDR blocks, such
/// as `.{ .list = &.{"10.1.0.0/16"} }`, which `init` copies and checks.
pub const TrustedProxies = proxies.TrustedProxies;

/// Unknown fields of the input: those of a JSON or form body are refused,
/// those of a query ignored; a DTO may say otherwise.
pub const UnknownFieldsOptions = struct {
    body: dto.UnknownFields = .reject,
    query: dto.UnknownFields = .ignore,
};

pub const JsonOptions = struct {
    /// The deepest nesting of a JSON body; deeper is 400.
    max_depth: u16 = 64,
};

/// The settings of a server, the second argument of `init`: where its
/// requests come from, the prefix of its routes, its static files, its
/// limits and its times. Durations are `std.Io.Duration`, written as
/// declaration literals: `.request_timeout = .fromSeconds(10)`.
pub const Options = struct {
    /// Where requests come from. It has no default: a server without it
    /// does not compile.
    listen: Listen,
    /// Before the routes of the controllers, such as "/api"; may come from
    /// the config: `init` copies it.
    prefix: []const u8 = "",
    /// Static files, mounts of `http.static`:
    /// `&.{http.static("/", .{ .root = "public" })}`. `init` copies and
    /// checks them, `start` opens their roots.
    static: []const Static = &.{},
    /// From whom to believe `X-Forwarded-For` and `Forwarded`; `init` copies
    /// a list.
    trusted_proxies: TrustedProxies = .all,
    unknown_fields: UnknownFieldsOptions = .{},
    json: JsonOptions = .{},
    /// The body of a request; a route may set its own.
    max_body_bytes: usize = 1 << 20,
    max_query_params: u32 = 100,
    /// Requests at work at once, without SSE streams.
    max_in_flight: u32 = 10_000,
    /// SSE streams at once.
    max_streams: u32 = 10_000,
    /// The deadline of a request; a route may set its own. Null: none.
    request_timeout: ?Duration = .fromSeconds(30),
    /// How long a stop waits for the requests at work.
    shutdown_grace: Duration = .fromSeconds(10),
    /// How long all `onFinish` of one request may take.
    finish_timeout: Duration = .fromSeconds(5),

    /// Where the requests of a server come from.
    pub const Listen = union(enum) {
        /// An `http.native.Backend` on this port of every IPv4 interface,
        /// with its defaults. The server makes it and frees it.
        port: u16,
        /// An `http.native.Backend` with these options: its address, limits
        /// and timeouts. The server makes it and frees it.
        native: NativeBackend.Options,
        /// A backend of your own, which outlives the server:
        /// `http.testing.Backend` in tests.
        backend: Backend,
    };
};

const Static = static_files.Static;

/// The options as the server keeps them: those of `Options` but `.listen`,
/// `.prefix` and `.static`, with the list of `.trusted_proxies` copied.
const Settings = struct {
    unknown_fields: UnknownFieldsOptions = .{},
    json: JsonOptions = .{},
    max_body_bytes: usize = 1 << 20,
    max_query_params: u32 = 100,
    max_in_flight: u32 = 10_000,
    max_streams: u32 = 10_000,
    request_timeout: ?Duration = .fromSeconds(30),
    shutdown_grace: Duration = .fromSeconds(10),
    finish_timeout: Duration = .fromSeconds(5),
    trusted_proxies: TrustedProxies = .all,
};

/// One route at run time.
const Route = struct {
    /// The method, the full pattern with the server's prefix, the
    /// controller and its method, as `ctx.route()` gives them.
    info: route_decls.RouteInfo,
    kind: route_decls.Kind,
    /// The controller the handler runs on, borrowed.
    controller: *anyopaque,
    /// Calls the handler on `controller`; a JSON value it returns becomes
    /// the response.
    handle: *const fn (controller: *anyopaque, ctx: *Context) anyerror!void,
    /// The `.on_close` of an SSE route.
    on_close: ?*const fn (controller: *anyopaque, ctx: *sse.Context) void,
    /// The names of the pattern's parameters, in the order of the values
    /// the router gives.
    params: []const []const u8,
    /// Instead of the server's `.max_body_bytes`.
    max_body_bytes: ?usize,
    timeout: route_decls.Timeout,
    heartbeat: ?std.Io.Duration,
    /// The route's own middleware, after the server's: the controller's,
    /// then the method's.
    links: []const mw.Link,
};

/// What the routes and the mounts need of the backend: the routes' is
/// known at compile time, the mounts' at run time.
const Needs = struct {
    /// The first SSE route, which needs `flush`.
    flush: ?u32 = null,
    /// Mounts of `.static`, which need `streaming_response`.
    static_mounts: usize = 0,
};

/// Builds a server from its parts and its options, without I/O.
///
/// `parts` is a struct literal of what the compiler checks by type:
/// `.controllers`, a tuple of pointers to controllers, at least one, and
/// optionally `.middleware`, `.error_handler` and `.strict_errors`.
/// `options` are its settings, `Options`.
///
/// `.middleware` is the server's middleware (middleware.zig): every
/// request runs it, in order, before its route is applied, then the
/// middleware of its controller and of its method. The chain of each
/// route is built here, at compile time, and the compiler checks every
/// element; the objects it points to are borrowed.
///
/// `.error_handler = &app_errors` turns every error into its response
/// (`mapError`, then `handle`); without it errors go
/// out as problem+json. The strict error check runs here, at compile time:
/// an error of the application that the error handler gives 500 through
/// `.fallback`, or that no error handler maps, fails the build, as does a
/// handler that returns `anyerror`. `.strict_errors = false`, known at
/// compile time, turns the check off.
///
/// The controllers, the error handler, the objects of the middleware and
/// a backend of `.listen = .{ .backend = ... }` are borrowed and live as
/// long as the server; the prefix, the list of trusted proxies and the
/// strings of the mounts are copied, and the backend of `.port` or
/// `.native` is the server's own. No I/O: the backend listens and the
/// roots of the mounts open in `start`.
pub fn init(gpa: std.mem.Allocator, parts: anytype, options: Options) InitError!Server {
    const P = @TypeOf(parts);
    const p = comptime plan.of(P);
    // The loops below unroll once per route and per setting.
    @setEvalBranchQuota(1000 + 100 * p.routes.len);

    var settings: Settings = .{};
    inline for (@typeInfo(Settings).@"struct".field_names) |name| @field(settings, name) = @field(options, name);
    if (!validSettings(settings)) return error.InvalidConfiguration;

    if (!path_rules.validPrefix(options.prefix)) return error.InvalidConfiguration;
    const prefix = try gpa.dupe(u8, options.prefix);
    errdefer gpa.free(prefix);

    settings.trusted_proxies = try trustedProxiesOf(gpa, options.trusted_proxies);
    errdefer freeSettings(gpa, settings);
    const trust = try proxies.Trust.init(gpa, settings.trusted_proxies);
    errdefer trust.deinit(gpa);

    const mounts = try static_files.copyMounts(gpa, options.static);
    errdefer static_files.freeMounts(gpa, mounts);

    const links = try linksOf(gpa, p, parts);
    errdefer gpa.free(links);

    const table = try gpa.alloc(Route, p.routes.len);
    errdefer gpa.free(table);
    var filled: usize = 0;
    errdefer for (table[0..filled]) |r| gpa.free(r.info.pattern);
    // Where the links of each route begin in `links`.
    comptime var offset: usize = p.global.len;
    inline for (p.routes, 0..) |r, i| {
        const pattern = if (prefix.len + r.pattern.len == 0)
            try gpa.dupe(u8, "/")
        else
            try std.mem.concat(gpa, u8, &.{ prefix, r.pattern });
        table[i] = .{
            .info = .{ .method = r.method, .pattern = pattern, .controller = r.controller_name, .handler = r.handler },
            .kind = r.kind,
            .controller = parts.controllers[r.controller_index],
            .handle = HandlerOf(r.Controller, r.handler, r.kind).handle,
            .on_close = if (r.on_close) |name| OnCloseOf(r.Controller, name).call else null,
            .params = r.params,
            .max_body_bytes = r.max_body_bytes,
            .timeout = r.timeout,
            .heartbeat = r.heartbeat,
            .links = links[offset..][0..r.chain.len],
        };
        offset += r.chain.len;
        filled += 1;
    }

    // Last: nothing fails after it.
    const native, const backend = try backendOf(gpa, options.listen);
    return .{ .internal = .{
        .gpa = gpa,
        .backend = backend,
        .native = native,
        .prefix = prefix,
        .routes = table,
        .router = .{ .nodes = p.nodes, .prefix = prefix, .max_params = p.max_params },
        .links = links,
        .middleware = links[0..p.global.len],
        .settings = settings,
        .trust = trust,
        .needs = needsOf(p, mounts.len),
        .error_handler = if (@hasField(P, "error_handler")) .of(p.Handler, parts.error_handler) else .default,
        .mounts = mounts,
    } };
}

/// The backend of `.listen`, and the native backend the server makes for
/// `.port` and `.native`, which `deinit` frees.
fn backendOf(gpa: std.mem.Allocator, listen: Options.Listen) InitError!struct { ?*NativeBackend, Backend } {
    const native_options: NativeBackend.Options = switch (listen) {
        .backend => |own| return .{ null, own },
        .port => |port| .{ .port = port },
        .native => |given| given,
    };
    const native = try gpa.create(NativeBackend);
    errdefer gpa.destroy(native);
    native.* = try .init(gpa, native_options);
    return .{ native, native.backend() };
}

/// The links of every chain of `p`, in one allocation: the server's
/// middleware, each with the object `parts.middleware` points to, then
/// the own middleware of each route, a field of a controller with that
/// controller.
fn linksOf(gpa: std.mem.Allocator, comptime p: plan.Plan, parts: anytype) error{OutOfMemory}![]mw.Link {
    const own = comptime routeLinks(p);
    const links = try gpa.alloc(mw.Link, p.global.len + own.len);
    inline for (p.global, 0..) |e, i| {
        links[i] = comptime mw.linkOf(e);
        if (e.binding == .pointer) links[i].ptr = mw.objectAt(parts.middleware, e.path);
    }
    const count = @typeInfo(@TypeOf(parts.controllers)).@"struct".field_names.len;
    var controllers: [count]*anyopaque = undefined;
    inline for (&controllers, 0..) |*slot, i| slot.* = parts.controllers[i];
    for (own, links[p.global.len..]) |l, *link| {
        link.* = l.link;
        if (l.controller) |ci| link.ptr = controllers[ci];
    }
    return links;
}

/// A link of a route's own chain, known at compile time, and the
/// controller its object hangs on, for a field.
const RouteLink = struct { link: mw.Link, controller: ?usize };

fn routeLinks(comptime p: plan.Plan) []const RouteLink {
    var count: usize = 0;
    for (p.routes) |r| count += r.chain.len;
    @setEvalBranchQuota(1000 + 200 * count);
    var out: [count]RouteLink = undefined;
    var at: usize = 0;
    for (p.routes) |r| {
        for (r.chain) |e| {
            out[at] = .{ .link = mw.linkOf(e), .controller = if (e.binding == .field) r.controller_index else null };
            at += 1;
        }
    }
    const final = out;
    return &final;
}

fn needsOf(comptime p: plan.Plan, static_mounts: usize) Needs {
    const flush: ?u32 = comptime first: {
        for (p.routes, 0..) |r, i| if (r.kind == .sse) break :first i;
        break :first null;
    };
    return .{ .flush = flush, .static_mounts = static_mounts };
}

fn validSettings(s: Settings) bool {
    if (s.max_in_flight == 0 or s.max_streams == 0 or s.json.max_depth == 0) return false;
    if (s.request_timeout) |t| if (t.nanoseconds <= 0) return false;
    return s.shutdown_grace.nanoseconds >= 0 and s.finish_timeout.nanoseconds >= 0;
}

/// `.trusted_proxies`, its list copied.
fn trustedProxiesOf(gpa: std.mem.Allocator, value: TrustedProxies) error{OutOfMemory}!TrustedProxies {
    return switch (value) {
        .list => |list| .{ .list = try copyList(gpa, list) },
        else => value,
    };
}

/// A copy of a list of strings.
fn copyList(gpa: std.mem.Allocator, list: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const copy = try gpa.alloc([]const u8, list.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |item| gpa.free(item);
        gpa.free(copy);
    }
    for (copy, list) |*slot, item| {
        slot.* = try gpa.dupe(u8, item);
        done += 1;
    }
    return copy;
}

fn freeSettings(gpa: std.mem.Allocator, settings: Settings) void {
    switch (settings.trusted_proxies) {
        .list => |list| {
            for (list) |item| gpa.free(item);
            gpa.free(list);
        },
        else => {},
    }
}

/// The handler of a route, type-erased: a JSON value goes out with its
/// status, written through the response's buffer when the response goes
/// out; `void` leaves the response to what the handler wrote.
fn HandlerOf(comptime C: type, comptime name: []const u8, comptime kind: route_decls.Kind) type {
    return struct {
        fn handle(ptr: *anyopaque, ctx: *Context) anyerror!void {
            const self: *C = @ptrCast(@alignCast(ptr));
            const method = @field(C, name);
            switch (kind) {
                .rest => {
                    const result = method(self, ctx);
                    const out = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
                    if (@TypeOf(out) != void) try ctx.response.status(out.status).internal.setValue(out.value);
                },
                .sse => {
                    var stream: sse.Context = .{ .request = &ctx.request, .locals = &ctx.locals, .internal = .{ .http = ctx } };
                    try method(self, &stream);
                },
            }
        }
    };
}

fn OnCloseOf(comptime C: type, comptime name: []const u8) type {
    return struct {
        fn call(ptr: *anyopaque, ctx: *sse.Context) void {
            const self: *C = @ptrCast(@alignCast(ptr));
            @field(C, name)(self, ctx);
        }
    };
}

/// Checks that the backend can do what the routes and the mounts need,
/// opens the roots of the mounts, starts the backend and returns once the
/// server takes requests. On an error nothing runs and the server is
/// `stopped`; a second `start` is `error.InvalidState`.
pub fn start(server: *Server, io: std.Io) StartError!void {
    {
        server.internal.mutex.lockUncancelable(io);
        defer server.internal.mutex.unlock(io);
        if (server.internal.state_value.load(.monotonic) != .configured) return error.InvalidState;
        server.internal.state_value.store(.starting, .release);
    }
    if (!server.backendCanServe()) {
        server.markStopped(io);
        return error.UnsupportedByBackend;
    }
    static_files.openRoots(server.internal.mounts, io) catch |err| {
        server.markStopped(io);
        return err;
    };
    // The stop runs in a task of its own: `requestStop` only wakes it. It
    // starts first, so that a stop requested while the backend starts is
    // not lost.
    server.internal.lifecycle = lifecycle: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :lifecycle io.concurrent(runLifecycle, .{ server, io }) catch |err| {
            server.markStopped(io);
            return err;
        };
    };
    server.internal.backend.start(io, flow.handler(server)) catch |err| {
        {
            server.internal.mutex.lockUncancelable(io);
            defer server.internal.mutex.unlock(io);
            server.internal.rollback = true;
        }
        server.internal.start_done.set(io);
        server.internal.stop_event.set(io);
        server.joinLifecycle(io);
        server.markStopped(io);
        return err;
    };
    {
        server.internal.mutex.lockUncancelable(io);
        defer server.internal.mutex.unlock(io);
        // A stop requested while the backend started: straight to draining.
        server.internal.state_value.store(if (server.internal.stop_requested) .draining else .running, .release);
    }
    server.internal.start_done.set(io);
}

/// Whether the backend has every capability the routes need; logs the
/// route that needs one it lacks.
fn backendCanServe(server: *const Server) bool {
    const can = server.internal.backend.capabilities();
    if (server.internal.needs.flush) |index| if (!can.flush) {
        const info = server.internal.routes[index].info;
        log.warn("{s}.{s} (GET {s}) is an SSE route, which needs a backend with flush; this backend has none", .{ info.controller, info.handler, info.pattern });
        return false;
    };
    if (server.internal.needs.static_mounts > 0 and !can.streaming_response) {
        log.warn("static files need a backend with streaming_response; this backend has none", .{});
        return false;
    }
    return true;
}

/// Waits until the server has stopped. Returns at once with the error of a
/// backend that broke: the server then stops by itself. `error.InvalidState`
/// before `start`. Canceling the wait does not stop the server.
pub fn wait(server: *Server, io: std.Io) WaitError!void {
    if (server.internal.state_value.load(.acquire) == .configured) return error.InvalidState;
    try server.internal.wait_event.wait(io);
    return server.fatalError(io);
}

/// The error of a backend that broke, if one did.
fn fatalError(server: *Server, io: std.Io) Backend.FatalError!void {
    server.internal.mutex.lockUncancelable(io);
    defer server.internal.mutex.unlock(io);
    if (server.internal.fatal) |err| return err;
}

/// `start` and `wait`: for a service that runs one server until it stops.
pub fn run(server: *Server, io: std.Io) (StartError || WaitError)!void {
    try server.start(io);
    return server.wait(io);
}

/// Begins a graceful stop. From any task, also from a handler; never
/// waits; a second call does nothing. The backend takes no new requests,
/// the SSE streams are closed (each sends what was published to it before,
/// then the end of its response), the requests at work and those streams
/// get `.shutdown_grace` to end (less, by the deadline of a `shutdown`),
/// those that outlive it are canceled without a response or cut, and the
/// server stops.
pub fn requestStop(server: *Server, io: std.Io) void {
    server.internal.mutex.lockUncancelable(io);
    defer server.internal.mutex.unlock(io);
    switch (server.internal.state_value.load(.monotonic)) {
        .configured => {
            server.internal.state_value.store(.stopped, .release);
            server.internal.wait_event.set(io);
            server.internal.shutdown_event.set(io);
        },
        .starting, .running => |current| {
            // While starting, `start` moves on to draining itself.
            if (current == .running) server.internal.state_value.store(.draining, .release);
            server.internal.stop_requested = true;
            server.internal.stop_event.set(io);
        },
        .draining, .stopped => {},
    }
}

/// `requestStop` and a wait for the stop, which returns 250 ms before
/// `deadline` at the latest. The deadline cuts `.shutdown_grace`, also a
/// grace that began before this call: the grace ends by `deadline` less
/// one second, `.finish_timeout` and those 250 ms, so that the requests it
/// cancels have time to end and the caller time for what comes after. Of
/// several calls the earliest deadline counts.
///
/// `error.ShutdownTimeout` when the server has not stopped by then: a
/// handler that ignores its cancelation. The server stays in `draining`
/// until such requests end. Treat it as fatal and end the process; `deinit`
/// would wait for them without a limit. Once stopped, the error of a
/// backend that broke, as `wait` returns it.
pub fn shutdown(server: *Server, io: std.Io, deadline: std.Io.Clock.Timestamp) ShutdownError!void {
    const due: core.Deadline = .at(deadline.toClock(io, .awake).raw);
    server.limitGrace(io, due);
    server.requestStop(io);
    waiting.untilSet(&server.internal.shutdown_event, io, before(due, shutdown_reserve)) catch |err| switch (err) {
        error.Timeout => return error.ShutdownTimeout,
        error.Canceled => |e| return e,
    };
    return server.fatalError(io);
}

/// Keeps the earliest deadline of a `shutdown` and wakes the lifecycle
/// task, whose grace it may cut.
fn limitGrace(server: *Server, io: std.Io, due: core.Deadline) void {
    {
        server.internal.mutex.lockUncancelable(io);
        defer server.internal.mutex.unlock(io);
        server.internal.deadline = if (server.internal.deadline) |given| given.earliest(due) else due;
    }
    server.internal.idle.set(io);
}

/// `due`, `by` earlier.
fn before(due: core.Deadline, by: Duration) core.Deadline {
    return .{ .expires = .{ .nanoseconds = due.expires.nanoseconds -| by.nanoseconds } };
}

/// The time a stop keeps after its grace, past `.finish_timeout`, for the
/// requests it cancels to end: a deadline ends the grace this much earlier.
const cancel_budget: Duration = .fromSeconds(1);

/// How much earlier than its deadline `shutdown` returns, so that the
/// caller still has time for what comes after it.
const shutdown_reserve: Duration = .fromMilliseconds(250);

/// Running, and the backend takes requests. Thread-safe; for health
/// checks.
pub fn isReady(server: *const Server) bool {
    return server.state() == .running and server.internal.backend.isReady();
}

/// The state now. Thread-safe; for health checks.
pub fn state(server: *const Server) State {
    return server.internal.state_value.load(.acquire);
}

/// Stops the server if it runs, waits for the stop and frees the tables,
/// and last the backend of `.listen = .port` or `.native`. No other task
/// may still be in `wait`, `run` or `shutdown`.
pub fn deinit(server: *Server, io: std.Io) void {
    // No cancelation point: a cancelation request of the caller stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server.requestStop(io);
    server.joinLifecycle(io);
    static_files.closeRoots(server.internal.mounts, io);
    static_files.freeMounts(server.internal.gpa, server.internal.mounts);
    freeSettings(server.internal.gpa, server.internal.settings);
    server.internal.trust.deinit(server.internal.gpa);
    for (server.internal.routes) |r| server.internal.gpa.free(r.info.pattern);
    server.internal.gpa.free(server.internal.routes);
    server.internal.gpa.free(server.internal.links);
    server.internal.gpa.free(server.internal.prefix);
    if (server.internal.native) |native| {
        native.deinit();
        server.internal.gpa.destroy(native);
    }
    server.* = undefined;
}

fn markStopped(server: *Server, io: std.Io) void {
    {
        server.internal.mutex.lockUncancelable(io);
        defer server.internal.mutex.unlock(io);
        server.internal.state_value.store(.stopped, .release);
    }
    server.internal.wait_event.set(io);
    server.internal.shutdown_event.set(io);
}

fn joinLifecycle(server: *Server, io: std.Io) void {
    const future = if (server.internal.lifecycle) |*future| future else return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    future.await(io);
    server.internal.lifecycle = null;
}

/// The lifecycle task: waits for a stop and leads it. The backend takes no
/// new requests and the SSE streams are closed at once; the requests at
/// work, and the streams that still send what was published before, get
/// `.shutdown_grace` to end, or less by the deadline of a `shutdown`; then
/// the backend cancels what still runs (a request it cancels ends without
/// a response, a stream cut) and the server stops once every task of the
/// backend has ended.
fn runLifecycle(server: *Server, io: std.Io) void {
    // Nothing cancels this task, and its waits are no cancelation points.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server.internal.stop_event.waitUncancelable(io);
    server.internal.start_done.waitUncancelable(io);
    if (server.internal.rollback) return;
    const began = std.Io.Clock.awake.now(io);
    server.internal.backend.stopAccepting(io);
    flow.closeStreams(server, io);
    server.waitIdle(io, began);
    server.internal.backend.cancelAll(io);
    server.internal.backend.wait(io);
    server.markStopped(io);
}

/// Waits until no request is at work and no stream is open, or the grace
/// of the stop that `began` ends: the stop has closed the streams, which
/// end once they have sent what was published before. A deadline of a
/// `shutdown` that comes meanwhile wakes it to cut the grace. Only the
/// lifecycle task calls it.
fn waitIdle(server: *Server, io: std.Io, began: std.Io.Timestamp) void {
    while (true) {
        server.internal.idle.reset();
        // Read-modify-writes, not loads: they order the reset before the
        // `set` of the request or the stream that drops its count last. A
        // plain load may read the count from before that while the reset
        // lands after its `set`, and the stop would sleep through it.
        if (server.internal.in_flight.fetchAdd(0, .acq_rel) == 0 and server.internal.streams.fetchAdd(0, .acq_rel) == 0) return;
        waiting.untilSet(&server.internal.idle, io, server.graceEnd(io, began)) catch |err| switch (err) {
            error.Timeout => return,
            // The lifecycle task waits with cancelation blocked.
            error.Canceled => unreachable,
        };
    }
}

/// The end of the grace of the stop that `began`: `.shutdown_grace` later,
/// or earlier by the deadline of a `shutdown`, which keeps one second,
/// `.finish_timeout` and the reserve of `shutdown` for what comes after;
/// never before `began`.
fn graceEnd(server: *Server, io: std.Io, began: std.Io.Timestamp) core.Deadline {
    const grace: core.Deadline = .after(began, server.internal.settings.shutdown_grace);
    const due = due: {
        server.internal.mutex.lockUncancelable(io);
        defer server.internal.mutex.unlock(io);
        break :due server.internal.deadline orelse return grace;
    };
    const after_grace: Duration = .{ .nanoseconds = cancel_budget.nanoseconds +| server.internal.settings.finish_timeout.nanoseconds +|
        shutdown_reserve.nanoseconds };
    const cut = before(due, after_grace);
    if (cut.expires.nanoseconds < began.nanoseconds) return .at(began);
    return grace.earliest(cut);
}

const testing = std.testing;
const TestingBackend = @import("testing/Backend.zig");
const Json = @import("dto.zig").Json;
const normalize = @import("path.zig").normalize;

const UsersV1Controller = struct {
    pub const http_routes = route_decls.routes(.{
        .prefix = "/v1/users",
        .methods = .{
            .list = route_decls.get("", .{}),
            .get = route_decls.get("/{id}", .{ .timeout = std.Io.Duration.fromSeconds(5) }),
            .remove = route_decls.delete("/{id}", .{}),
            .events = sse.get("/events", .{ .on_close = .eventsClosed }),
        },
    });

    pub fn list(_: *UsersV1Controller, _: *Context) !void {}
    pub fn get(_: *UsersV1Controller, _: *Context) !Json(struct { id: u64 }) {
        return .{ .value = .{ .id = 1 } };
    }
    pub fn remove(_: *UsersV1Controller, _: *Context) !void {}
    pub fn events(_: *UsersV1Controller, _: *sse.Context) !void {}
    pub fn eventsClosed(_: *UsersV1Controller, _: *sse.Context) void {}
};

const HealthController = struct {
    pub const http_routes = route_decls.routes(.{ .methods = .{
        .root = route_decls.get("", .{}),
        .check = route_decls.get("/health", .{}),
    } });

    pub fn root(_: *HealthController, _: *Context) !void {}
    pub fn check(_: *HealthController, _: *Context) !void {}
};

test "Server.init builds the table and deinit frees it" {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    // The prefix of a config: init copies it.
    const config_prefix = try testing.allocator.dupe(u8, "/api");
    var server = init(testing.allocator, .{ .controllers = .{ &users, &health } }, .{ .listen = .{ .backend = backend.backend() }, .prefix = config_prefix }) catch |err| {
        testing.allocator.free(config_prefix);
        return err;
    };
    defer server.deinit(testing.io);
    testing.allocator.free(config_prefix);

    const want = [_]struct { std.http.Method, []const u8, []const u8, []const u8 }{
        .{ .GET, "/api/v1/users", "UsersV1Controller", "list" },
        .{ .GET, "/api/v1/users/{id}", "UsersV1Controller", "get" },
        .{ .DELETE, "/api/v1/users/{id}", "UsersV1Controller", "remove" },
        .{ .GET, "/api/v1/users/events", "UsersV1Controller", "events" },
        .{ .GET, "/api", "HealthController", "root" },
        .{ .GET, "/api/health", "HealthController", "check" },
    };
    try testing.expectEqual(want.len, server.internal.routes.len);
    for (want, server.internal.routes) |w, r| {
        try testing.expectEqual(w[0], r.info.method);
        try testing.expectEqualStrings(w[1], r.info.pattern);
        try testing.expectEqualStrings(w[2], r.info.controller);
        try testing.expectEqualStrings(w[3], r.info.handler);
    }
    try testing.expectEqual(@as(*anyopaque, &users), server.internal.routes[1].controller);
    try testing.expectEqual(@as(*anyopaque, &health), server.internal.routes[5].controller);
    try testing.expectEqualStrings("id", server.internal.routes[2].params[0]);
    try testing.expectEqual(route_decls.Timeout{ .after = .fromSeconds(5) }, server.internal.routes[1].timeout);
    try testing.expectEqual(route_decls.Kind.sse, server.internal.routes[3].kind);
    try testing.expect(server.internal.routes[3].on_close != null and server.internal.routes[2].on_close == null);
    try testing.expectEqual(3, server.internal.needs.flush.?);
    try testing.expectEqualStrings("/api", server.internal.prefix);

    // The router of the server takes its prefix.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const values = try arena.alloc([]const u8, server.internal.router.max_params);
    const m = server.internal.router.match(.DELETE, try normalize(arena, "/api/v1/users/42"), values);
    try testing.expectEqualStrings("remove", server.internal.routes[m.found.route].info.handler);
    try testing.expectEqualStrings("42", m.found.params[0]);
    const root = server.internal.router.match(.GET, try normalize(arena, "/api/"), values);
    try testing.expectEqualStrings("root", server.internal.routes[root.found.route].info.handler);
    try testing.expectEqual(routing.Match.not_found, server.internal.router.match(.GET, try normalize(arena, "/v1/users"), values));
}

test "init checks the prefix without I/O" {
    var health: HealthController = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(testing.io);
    try testing.expectEqualStrings("/", server.internal.routes[0].info.pattern);
    try testing.expectEqualStrings("/health", server.internal.routes[1].info.pattern);
    try testing.expectEqual(State.configured, server.state());

    for ([_][]const u8{ "api", "/api/", "/", "//api", "/a//b", "/a b", "/a%20b", "/./a", "/a/..", "/{x}", "/a?b", "/a#b", "/caf\xc3\xa9" }) |prefix| {
        testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() }, .prefix = prefix })) catch |err| {
            std.debug.print("prefix {s}\n", .{prefix});
            return err;
        };
    }
}

test "init reads every option of section 4 with its default" {
    var health: HealthController = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    {
        var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() } });
        defer server.deinit(testing.io);
        const s = server.internal.settings;
        try testing.expectEqual(dto.UnknownFields.reject, s.unknown_fields.body);
        try testing.expectEqual(dto.UnknownFields.ignore, s.unknown_fields.query);
        try testing.expectEqual(64, s.json.max_depth);
        try testing.expectEqual(1 << 20, s.max_body_bytes);
        try testing.expectEqual(100, s.max_query_params);
        try testing.expectEqual(10_000, s.max_in_flight);
        try testing.expectEqual(10_000, s.max_streams);
        try testing.expectEqual(Duration.fromSeconds(30), s.request_timeout.?);
        try testing.expectEqual(Duration.fromSeconds(10), s.shutdown_grace);
        try testing.expectEqual(Duration.fromSeconds(5), s.finish_timeout);
        try testing.expect(s.trusted_proxies == .all);
        try testing.expectEqual(0, server.internal.needs.static_mounts);
        try testing.expectEqual(null, server.internal.needs.flush);
    }
    {
        // Nested literals, null, a duration in full, a list from the config.
        const cidrs = try testing.allocator.dupe(u8, "10.1.0.0/16");
        var server = init(testing.allocator, .{
            .controllers = .{&health},
        }, .{
            .listen = .{ .backend = backend.backend() },
            .unknown_fields = .{ .body = .ignore },
            .json = .{ .max_depth = 16 },
            .max_body_bytes = 8 << 20,
            .max_query_params = 20,
            .max_in_flight = 64,
            .max_streams = 8,
            .request_timeout = null,
            .shutdown_grace = std.Io.Duration.fromSeconds(1),
            .finish_timeout = std.Io.Duration.fromMilliseconds(500),
            .trusted_proxies = .{ .list = &.{ cidrs, "fc00::/7" } },
        }) catch |err| {
            testing.allocator.free(cidrs);
            return err;
        };
        defer server.deinit(testing.io);
        testing.allocator.free(cidrs);
        const s = server.internal.settings;
        try testing.expectEqual(dto.UnknownFields.ignore, s.unknown_fields.body);
        try testing.expectEqual(dto.UnknownFields.ignore, s.unknown_fields.query);
        try testing.expectEqual(16, s.json.max_depth);
        try testing.expectEqual(8 << 20, s.max_body_bytes);
        try testing.expectEqual(20, s.max_query_params);
        try testing.expectEqual(64, s.max_in_flight);
        try testing.expectEqual(8, s.max_streams);
        try testing.expectEqual(null, s.request_timeout);
        try testing.expectEqual(Duration.fromSeconds(1), s.shutdown_grace);
        try testing.expectEqual(Duration.fromMilliseconds(500), s.finish_timeout);
        try testing.expectEqualStrings("10.1.0.0/16", s.trusted_proxies.list[0]);
        try testing.expectEqualStrings("fc00::/7", s.trusted_proxies.list[1]);
    }
    try testing.expect(try trustedProxiesOf(testing.allocator, .none) == .none);
    try testing.expect(try trustedProxiesOf(testing.allocator, .private) == .private);
    // A whole TrustedProxies, as a config would give it, and a slice.
    const from_config: TrustedProxies = .{ .list = &.{"192.168.0.0/16"} };
    const copied = try trustedProxiesOf(testing.allocator, from_config);
    defer freeSettings(testing.allocator, .{ .trusted_proxies = copied });
    try testing.expect(copied.list.ptr != from_config.list.ptr);
    try testing.expectEqualStrings("192.168.0.0/16", copied.list[0]);
    const slice: []const []const u8 = &.{ "10.0.0.0/8", "::1/128" };
    const from_slice = try trustedProxiesOf(testing.allocator, .{ .list = slice });
    defer freeSettings(testing.allocator, .{ .trusted_proxies = from_slice });
    try testing.expectEqualStrings("::1/128", from_slice.list[1]);

    // Values that cannot work.
    const backend_value = backend.backend();
    const controllers = .{&health};
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .max_in_flight = 0 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .max_streams = 0 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .json = .{ .max_depth = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .request_timeout = Duration.zero }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .shutdown_grace = Duration.fromSeconds(-1) }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .finish_timeout = Duration.fromSeconds(-1) }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend_value }, .trusted_proxies = .{ .list = &.{ "10.0.0.0/8", "10.0.0.0/33" } } }));
}

test "typed options take declaration literals" {
    var health: HealthController = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{
        .listen = .{ .backend = backend.backend() },
        .request_timeout = .fromSeconds(10),
        .shutdown_grace = .fromSeconds(3),
    });
    defer server.deinit(testing.io);
    try testing.expectEqual(10, server.internal.settings.request_timeout.?.toSeconds());
    try testing.expectEqual(3, server.internal.settings.shutdown_grace.toSeconds());
    try testing.expect(server.internal.native == null);
}

test "a server on .listen = .port owns its native backend" {
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .port = 0 } });
    // deinit without start: the backend is freed, and it never listened.
    defer server.deinit(testing.io);
    const native = server.internal.native.?;
    try testing.expectEqual(@as(*anyopaque, native), server.internal.backend.ptr);
    try testing.expectEqual(null, native.listener);
    try testing.expectEqual(0, native.port());
    var any: [64]u8 = undefined;
    try testing.expectEqualStrings("0.0.0.0:0", try std.fmt.bufPrint(&any, "{f}", .{native.address}));
}

test "a server on .listen = .native takes the backend's options" {
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{
        .native = .{ .address = "127.0.0.1", .port = 0, .timeouts = .{ .idle = .fromSeconds(5) } },
    } });
    defer server.deinit(testing.io);
    const native = server.internal.native.?;
    try testing.expectEqual(5, native.timeouts.idle.toSeconds());
    var address: [64]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1:0", try std.fmt.bufPrint(&address, "{f}", .{native.address}));
    // Options the backend refuses: the server is not built, and nothing leaks.
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{
        .native = .{ .address = "localhost", .port = 80 },
    } }));
}

fn initAndDeinit(gpa: std.mem.Allocator) !void {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    var backend: TestingBackend = .init(gpa);
    defer backend.deinit();
    var server = try init(gpa, .{
        .controllers = .{ &users, &health },
    }, .{
        .listen = .{ .backend = backend.backend() },
        .prefix = "/api",
        .trusted_proxies = .{ .list = &.{ "10.0.0.0/8", "fc00::/7" } },
    });
    server.deinit(testing.io);
    // The native backend the server makes for itself.
    var on_port = try init(gpa, .{ .controllers = .{&health} }, .{ .listen = .{ .port = 0 }, .prefix = "/api" });
    on_port.deinit(testing.io);
}

test "Server.init frees what it took when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{});
}

/// A backend that serves nothing and can only what `can` says; it counts
/// the calls of its start.
const FakeBackend = struct {
    can: Backend.Capabilities,
    starts: u32 = 0,

    fn backend(f: *FakeBackend) Backend {
        return .{ .ptr = f, .vtable = &.{
            .capabilities = capabilitiesOf,
            .start = startFake,
            .stopAccepting = nothing,
            .cancelAll = nothing,
            .wait = nothing,
            .isReady = ready,
        } };
    }

    fn capabilitiesOf(ptr: *anyopaque) Backend.Capabilities {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        return f.can;
    }

    fn startFake(ptr: *anyopaque, _: std.Io, _: Backend.Handler) Backend.StartError!void {
        const f: *FakeBackend = @ptrCast(@alignCast(ptr));
        f.starts += 1;
    }

    fn nothing(_: *anyopaque, _: std.Io) void {}

    fn ready(_: *anyopaque) bool {
        return true;
    }
};

test "start refuses a backend without a capability a route needs" {
    const io = testing.io;
    var fake: FakeBackend = .{ .can = .{ .http1 = true, .streaming_response = true } };
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};

    // An SSE route needs flush.
    var server = try init(testing.allocator, .{ .controllers = .{ &users, &health } }, .{ .listen = .{ .backend = fake.backend() } });
    defer server.deinit(io);
    const level = testing.log_level;
    testing.log_level = .err; // the warning names the route
    defer testing.log_level = level;
    try testing.expectError(error.UnsupportedByBackend, server.start(io));
    try testing.expectEqual(0, fake.starts);
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.InvalidState, server.start(io));
    try server.wait(io);

    // Without SSE the same backend serves.
    var plain = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = fake.backend() } });
    defer plain.deinit(io);
    try plain.start(io);
    try testing.expectEqual(1, fake.starts);
    try plain.shutdown(io, far(io));

    // Static files need streaming_response.
    var no_stream: FakeBackend = .{ .can = .{ .http1 = true, .flush = true } };
    var with_static = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = no_stream.backend() }, .static = &.{static_files.static("/", .{ .root = "public" })} });
    defer with_static.deinit(io);
    try testing.expectEqual(1, with_static.internal.needs.static_mounts);
    try testing.expectError(error.UnsupportedByBackend, with_static.start(io));
    try testing.expectEqual(0, no_stream.starts);
}

const GateController = struct {
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,

    pub const http_routes = route_decls.routes(.{ .methods = .{ .slow = route_decls.get("/slow", .{}) } });

    pub fn slow(self: *GateController, ctx: *Context) !void {
        self.entered.set(ctx.io());
        try self.gate.wait(ctx.io());
    }
};

fn requestSlow(backend: *TestingBackend, io: std.Io) TestingBackend.RequestError!TestingBackend.Response {
    return backend.request(io, .{ .method = .GET, .target = "/slow" });
}

test "lifecycle: configured → running → draining → stopped; a second start is InvalidState" {
    const io = testing.io;
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var gate: GateController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&gate} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(io);

    try testing.expectEqual(State.configured, server.state());
    try testing.expect(!server.isReady());
    try testing.expectError(error.InvalidState, server.wait(io));
    try testing.expectError(error.NotStarted, backend.request(io, .{ .method = .GET, .target = "/slow" }));

    try server.start(io);
    try testing.expectEqual(State.running, server.state());
    try testing.expect(server.isReady());
    try testing.expectError(error.InvalidState, server.start(io));

    // A request at work holds the stop in draining until it ends.
    var pending = try io.concurrent(requestSlow, .{ &backend, io });
    var pending_done = false;
    defer if (!pending_done) {
        gate.gate.set(io);
        if (pending.await(io)) |res| {
            var r = res;
            r.deinit();
        } else |_| {}
    };
    try gate.entered.wait(io);
    server.requestStop(io);
    server.requestStop(io); // a second call does nothing
    try testing.expectEqual(State.draining, server.state());
    try testing.expect(!server.isReady());

    // The backend takes no new requests once the stop has begun.
    var tries: u32 = 0;
    while (backend.backend().isReady()) : (tries += 1) {
        if (tries == 2000) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.NotStarted, backend.request(io, .{ .method = .GET, .target = "/slow" }));
    try testing.expectEqual(State.draining, server.state());

    // The request at work ends with its response, then the server stops.
    gate.gate.set(io);
    pending_done = true;
    var res = try pending.await(io);
    defer res.deinit();
    try testing.expectEqual(204, res.status);
    try server.wait(io);
    try testing.expectEqual(State.stopped, server.state());
    try server.shutdown(io, far(io));
    try testing.expectError(error.InvalidState, server.start(io));
}

test "shutdown and deinit of a server that never started" {
    const io = testing.io;
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(io);
    try server.shutdown(io, far(io));
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.InvalidState, server.start(io));
}

/// A route that holds its request: on a gate the test opens in its
/// `defer`, or for `sleep`. `deaf` ignores the request's cancelation and
/// waits for the gate alone.
const HoldController = struct {
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    sleep: ?Duration = null,
    deaf: bool = false,
    /// The handler's wait ended with `error.Canceled`, at `canceled_at`.
    canceled: std.atomic.Value(bool) = .init(false),
    canceled_at: std.Io.Timestamp = .zero,

    pub const http_routes = route_decls.routes(.{ .methods = .{ .hold = route_decls.get("/hold", .{}) } });

    pub fn hold(self: *HoldController, ctx: *Context) !void {
        const io = ctx.io();
        self.entered.set(io);
        if (self.deaf) return self.gate.waitUncancelable(io);
        const held = if (self.sleep) |d| io.sleep(d, .awake) else self.gate.wait(io);
        held catch |err| {
            self.canceled_at = std.Io.Clock.awake.now(io);
            self.canceled.store(true, .release);
            return err;
        };
    }
};

/// A server of a `HoldController` with the grace `grace` and a
/// `.finish_timeout` of 200 ms, started, with one request held in it;
/// `stop` opens the gate, ends the request and frees it all.
const HoldFixture = struct {
    holder: HoldController = .{},
    backend: TestingBackend = undefined,
    server: Server = undefined,
    pending: std.Io.Future(TestingBackend.RequestError!TestingBackend.Response) = undefined,

    fn start(f: *HoldFixture, io: std.Io, grace: Duration) !void {
        f.backend = .init(testing.allocator);
        errdefer f.backend.deinit();
        f.server = try init(testing.allocator, .{ .controllers = .{&f.holder} }, .{
            .listen = .{ .backend = f.backend.backend() },
            .shutdown_grace = grace,
            .finish_timeout = .fromMilliseconds(200),
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
        f.pending = try io.concurrent(requestHold, .{ &f.backend, io });
        f.holder.entered.wait(io) catch |err| {
            f.holder.gate.set(io);
            if (f.pending.await(io)) |res| {
                var r = res;
                r.deinit();
            } else |_| {}
            return err;
        };
    }

    fn stop(f: *HoldFixture, io: std.Io) void {
        f.holder.gate.set(io);
        if (f.pending.await(io)) |res| {
            var r = res;
            r.deinit();
        } else |_| {}
        f.server.deinit(io);
        f.backend.deinit();
    }
};

fn requestHold(backend: *TestingBackend, io: std.Io) TestingBackend.RequestError!TestingBackend.Response {
    return backend.request(io, .{ .method = .GET, .target = "/hold" });
}

/// Milliseconds from `deadline` to `t`: negative before it.
fn msPast(deadline: std.Io.Clock.Timestamp, t: std.Io.Timestamp) i64 {
    return deadline.raw.durationTo(t).toMilliseconds();
}

const far = waiting.far;

test "a deadline before the end of the grace cancels the requests in time" {
    const io = testing.io;
    var f: HoldFixture = .{};
    try f.start(io, .fromSeconds(10));
    defer f.stop(io);

    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(3), .clock = .awake });
    try f.server.shutdown(io, deadline);
    const returned = std.Io.Clock.awake.now(io);
    // The grace ended 1 s, .finish_timeout and r before the deadline, not
    // after 10 s, and the request was canceled then.
    try testing.expect(f.holder.canceled.load(.acquire));
    try testing.expect(msPast(deadline, f.holder.canceled_at) >= -1450);
    try testing.expect(msPast(deadline, returned) <= -250 + 50);
    try testing.expectEqual(State.stopped, f.server.state());
}

test "a deadline that comes after requestStop shortens the grace" {
    const io = testing.io;
    var f: HoldFixture = .{};
    try f.start(io, .fromSeconds(10));
    defer f.stop(io);

    // The grace of 10 s runs: the backend takes no new requests.
    f.server.requestStop(io);
    var tries: u32 = 0;
    while (f.backend.backend().isReady()) : (tries += 1) {
        if (tries == 2000) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(2), .clock = .awake });
    try f.server.shutdown(io, deadline);
    const returned = std.Io.Clock.awake.now(io);
    try testing.expect(f.holder.canceled.load(.acquire));
    try testing.expect(msPast(deadline, f.holder.canceled_at) >= -1450);
    try testing.expect(msPast(deadline, returned) <= -250 + 50);
    try testing.expectEqual(State.stopped, f.server.state());
}

test "a handler deaf to cancelation: shutdown returns ShutdownTimeout by deadline − r" {
    const io = testing.io;
    var f: HoldFixture = .{ .holder = .{ .deaf = true } };
    try f.start(io, .fromSeconds(10));
    // Opens the gate first: the request ends, then the stop.
    defer f.stop(io);

    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake });
    try testing.expectError(error.ShutdownTimeout, f.server.shutdown(io, deadline));
    const returned = std.Io.Clock.awake.now(io);
    try testing.expect(msPast(deadline, returned) >= -250);
    try testing.expect(msPast(deadline, returned) <= -250 + 200);
    try testing.expectEqual(State.draining, f.server.state());
}

test "a far deadline keeps shutdown_grace" {
    const io = testing.io;
    var f: HoldFixture = .{ .holder = .{ .sleep = .fromMilliseconds(500) } };
    try f.start(io, .fromMilliseconds(300));
    defer f.stop(io);

    const begun = std.Io.Clock.awake.now(io);
    try f.server.shutdown(io, far(io));
    // The request of 500 ms is canceled at the end of the grace, 300 ms.
    try testing.expect(f.holder.canceled.load(.acquire));
    const at = begun.durationTo(f.holder.canceled_at).toMilliseconds();
    try testing.expect(at >= 300 - 100 and at <= 300 + 300);
    try testing.expectEqual(State.stopped, f.server.state());
}

test "a backend that fails stops the server: wait returns its error at once" {
    const io = testing.io;
    var f: HoldFixture = .{};
    try f.start(io, .fromSeconds(10));
    defer f.stop(io);
    const level = testing.log_level;
    testing.log_level = .err; // the server warns that its backend broke
    defer testing.log_level = level;

    f.backend.fail(io, error.Unavailable);
    // At once: the request held in the server keeps the stop in its grace.
    try testing.expectError(error.Unavailable, f.server.wait(io));
    try testing.expectEqual(State.draining, f.server.state());
    try testing.expect(!f.server.isReady());
}

test "after a failure shutdown returns the same error" {
    const io = testing.io;
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the server warns that its backend broke
    defer testing.log_level = level;

    backend.fail(io, error.Unavailable);
    // Only the first failure counts.
    backend.fail(io, error.Unexpected);
    try testing.expectError(error.Unavailable, server.shutdown(io, far(io)));
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.Unavailable, server.wait(io));
    try testing.expectError(error.Unavailable, server.shutdown(io, far(io)));
}

test "a testing backend that fails once the server has stopped does nothing" {
    const io = testing.io;
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .controllers = .{&health} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(io);
    try server.start(io);
    try server.shutdown(io, far(io));
    const level = testing.log_level;
    testing.log_level = .err; // were the failure taken, the server would warn
    defer testing.log_level = level;

    backend.fail(io, error.Unavailable);
    try server.wait(io);
    try server.shutdown(io, far(io));
}
