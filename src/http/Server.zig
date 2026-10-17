//! `http.Server` (design section 4): one type for every application.
//! `init` does the compile-time work over its options (plan.zig): it reads
//! the routes of the controllers, checks them and builds the router's trie;
//! at run time it copies the server's prefix and keeps the table of routes.
//!
//! ```zig
//! var server = try http.Server.init(gpa, .{
//!     .backend = native.backend(),
//!     .prefix = "/api", // only for controllers; may come from the config
//!     .controllers = .{ &todos_v1, &health },
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

const Server = @This();
const Duration = std.Io.Duration;
const log = std.log.scoped(.http);

gpa: std.mem.Allocator,
backend: Backend,
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
/// The options of `init` with their defaults.
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
/// Set when the grace of a stop is over and what still runs is canceled;
/// also when the server stops. `shutdown` waits a second more from here.
grace_over: std.Io.Event = .unset,
/// The requests at work, as `.max_in_flight` counts them: `serve` takes a
/// place before a request runs and gives it back at its end.
in_flight: std.atomic.Value(u32) = .init(0),
/// Set when `in_flight` or `streams` drops to zero. Only the lifecycle
/// task waits on it, and resets it before it looks at the counts.
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
/// `cache_control` with CR, LF or NUL.
pub const InitError = error{ InvalidConfiguration, OutOfMemory };
/// The backend's errors from its `start`, a task the runtime did not give,
/// a second `start` (`InvalidState`), a route that needs what the backend
/// cannot do (`UnsupportedByBackend`: an SSE route needs `flush`, static
/// files `streaming_response`), and the root of a `.static` mount that is
/// missing, is not a directory or does not open (`InvalidStaticRoot`,
/// logged with the mount, the path and the error of the system).
pub const StartError = Backend.StartError || error{ InvalidState, UnsupportedByBackend, InvalidStaticRoot };
/// The wait was canceled, or the server never started (`InvalidState`).
pub const WaitError = error{InvalidState} || std.Io.Cancelable;
pub const ShutdownError = error{ShutdownTimeout} || WaitError;

/// From whom to believe `X-Forwarded-For` and `Forwarded` (design section
/// 16): everybody, loopback and private networks, nobody, or a list of
/// CIDR blocks, such as `.{ .list = &.{"10.1.0.0/16"} }`, which `init`
/// copies and checks.
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

/// The options of `init` as the server keeps them, with the defaults of
/// design section 4. Durations are `std.Io.Duration`.
pub const Settings = struct {
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
    trusted_proxies: TrustedProxies = .all,
};

/// One route at run time.
pub const Route = struct {
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

/// What the routes need of the backend, known at compile time.
pub const Needs = struct {
    /// The first SSE route, which needs `flush`.
    flush: ?u32 = null,
    /// Mounts of `.static`, which need `streaming_response`.
    static_mounts: usize = 0,
};

/// Builds a server from `options`, a struct literal (design section 4):
/// `.backend` and `.controllers` (a tuple of pointers to controllers, at
/// least one), and optionally `.prefix` (before the routes of the
/// controllers, such as "/api"), `.middleware`, `.error_handler`,
/// `.strict_errors`, `.unknown_fields`, `.json`, `.max_body_bytes`,
/// `.max_query_params`, `.max_in_flight`, `.max_streams`,
/// `.request_timeout`, `.shutdown_grace`, `.finish_timeout` and
/// `.trusted_proxies`, as `Settings` describes them, and `.static`, a
/// tuple of mounts: `.{ http.static("/", .{ .root = "public" }) }`. The
/// options are
/// `anytype`, so a duration among them is written in full:
/// `std.Io.Duration.fromSeconds(10)`, not `.fromSeconds(10)`.
///
/// `.middleware` is the server's middleware (middleware.zig): every
/// request runs it, in order, before its route is applied, then the
/// middleware of its controller and of its method. The chain of each
/// route is built here, at compile time, and the compiler checks every
/// element; the objects it points to are borrowed.
///
/// `.error_handler = &app_errors` turns every error into its response
/// (`mapError`, then `handle`; design section 11); without it errors go
/// out as problem+json. The strict error check runs here, at compile time:
/// an error of the application that the error handler gives 500 through
/// `.fallback`, or that no error handler maps, fails the build, as does a
/// handler that returns `anyerror`. `.strict_errors = false`, known at
/// compile time, turns the check off.
///
/// The controllers, the error handler and the objects of the middleware
/// are borrowed and live as long as the server; the prefix, the list of
/// trusted proxies and the strings of the mounts are copied. No I/O: the
/// roots of the mounts open in `start`.
pub fn init(gpa: std.mem.Allocator, options: anytype) InitError!Server {
    const O = @TypeOf(options);
    const p = comptime plan.of(O);
    // The loops below unroll once per route and per setting.
    @setEvalBranchQuota(1000 + 100 * p.routes.len);

    var settings: Settings = .{};
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        // The list of trusted proxies is copied below.
        if (comptime std.mem.eql(u8, name, "trusted_proxies")) continue;
        if (@hasField(O, name)) @field(settings, name) = optionValue(@FieldType(Settings, name), @field(options, name));
    }
    if (!validSettings(settings)) return error.InvalidConfiguration;

    const given: []const u8 = if (@hasField(O, "prefix")) options.prefix else "";
    if (!validPrefix(given)) return error.InvalidConfiguration;
    const prefix = try gpa.dupe(u8, given);
    errdefer gpa.free(prefix);

    if (@hasField(O, "trusted_proxies")) settings.trusted_proxies = try trustedProxiesOf(gpa, options.trusted_proxies);
    errdefer freeSettings(gpa, settings);
    const trust = try proxies.Trust.init(gpa, settings.trusted_proxies);
    errdefer trust.deinit(gpa);

    const mounts = try static_files.copyMounts(gpa, if (@hasField(O, "static")) options.static else .{});
    errdefer static_files.freeMounts(gpa, mounts);

    const links = try linksOf(gpa, p, options);
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
            .controller = options.controllers[r.controller_index],
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

    return .{
        .gpa = gpa,
        .backend = options.backend,
        .prefix = prefix,
        .routes = table,
        .router = .{ .nodes = p.nodes, .prefix = prefix, .max_params = p.max_params },
        .links = links,
        .middleware = links[0..p.global.len],
        .settings = settings,
        .trust = trust,
        .needs = comptime needsOf(O, p),
        .error_handler = if (@hasField(O, "error_handler")) .of(p.Handler, options.error_handler) else .default,
        .mounts = mounts,
    };
}

/// The links of every chain of `p`, in one allocation: the server's
/// middleware, each with the object `options.middleware` points to, then
/// the own middleware of each route, a field of a controller with that
/// controller.
fn linksOf(gpa: std.mem.Allocator, comptime p: plan.Plan, options: anytype) error{OutOfMemory}![]mw.Link {
    const own = comptime routeLinks(p);
    const links = try gpa.alloc(mw.Link, p.global.len + own.len);
    inline for (p.global, 0..) |e, i| {
        links[i] = comptime mw.linkOf(e);
        if (e.binding == .pointer) links[i].ptr = mw.objectAt(options.middleware, e.path);
    }
    const count = @typeInfo(@TypeOf(options.controllers)).@"struct".field_names.len;
    var controllers: [count]*anyopaque = undefined;
    inline for (&controllers, 0..) |*slot, i| slot.* = options.controllers[i];
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

fn needsOf(comptime O: type, comptime p: plan.Plan) Needs {
    var needs: Needs = .{};
    for (p.routes, 0..) |r, i| {
        if (r.kind == .sse and needs.flush == null) needs.flush = i;
    }
    if (@hasField(O, "static")) {
        const info = @typeInfo(@FieldType(O, "static"));
        if (info == .@"struct") needs.static_mounts = info.@"struct".field_names.len;
    }
    return needs;
}

/// An option as the type of its field. In the options of an `anytype`, a
/// nested literal such as `.{ .body = .ignore }` has a struct type of its
/// own, which does not coerce to `UnknownFieldsOptions`: its fields are
/// taken one by one.
fn optionValue(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    if (V == T) return value;
    switch (@typeInfo(T)) {
        .@"struct" => if (@typeInfo(V) == .@"struct") {
            var out: T = .{};
            inline for (@typeInfo(V).@"struct".field_names) |name| {
                if (!@hasField(T, name)) @compileError("zefir.http: Server.init: " ++ plan.shortName(@typeName(T)) ++ " has no option ." ++ name);
                @field(out, name) = optionValue(@FieldType(T, name), @field(value, name));
            }
            return out;
        },
        .optional => |o| if (V != @TypeOf(null)) return optionValue(o.child, value),
        else => {},
    }
    return value;
}

fn validSettings(s: Settings) bool {
    if (s.max_in_flight == 0 or s.max_streams == 0 or s.json.max_depth == 0) return false;
    if (s.request_timeout) |t| if (t.nanoseconds <= 0) return false;
    return s.shutdown_grace.nanoseconds >= 0 and s.finish_timeout.nanoseconds >= 0;
}

/// `.trusted_proxies`, its list copied.
fn trustedProxiesOf(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}!TrustedProxies {
    const V = @TypeOf(value);
    if (V == TrustedProxies) return switch (value) {
        .list => |list| .{ .list = try copyList(gpa, list) },
        else => value,
    };
    if (@typeInfo(V) == .@"struct") {
        const names = @typeInfo(V).@"struct".field_names;
        if (comptime names.len != 1 or !std.mem.eql(u8, names[0], "list"))
            @compileError("zefir.http: Server.init: .trusted_proxies is .all, .private, .none or .{ .list = &.{\"10.1.0.0/16\"} }");
        return .{ .list = try copyList(gpa, value.list) };
    }
    return value;
}

/// A copy of a list of strings: a slice, or `&.{ ... }` of strings of
/// different types, such as a value from the config next to a literal.
/// Such a tuple is copied element by element: behind a pointer it does
/// not coerce to a slice safely.
fn copyList(gpa: std.mem.Allocator, list: anytype) error{OutOfMemory}![]const []const u8 {
    const info = @typeInfo(@TypeOf(list));
    const Tuple = if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .@"struct") info.pointer.child else void;
    const len = if (Tuple != void) @typeInfo(Tuple).@"struct".field_names.len else list.len;
    const copy = try gpa.alloc([]const u8, len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |item| gpa.free(item);
        gpa.free(copy);
    }
    if (Tuple != void) {
        inline for (0..len) |i| {
            const item: []const u8 = list.*[i];
            copy[i] = try gpa.dupe(u8, item);
            done += 1;
        }
    } else {
        const slice: []const []const u8 = list;
        for (copy, slice) |*slot, item| {
            slot.* = try gpa.dupe(u8, item);
            done += 1;
        }
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
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        if (server.state_value.load(.monotonic) != .configured) return error.InvalidState;
        server.state_value.store(.starting, .release);
    }
    if (!server.backendCanServe()) {
        server.markStopped(io);
        return error.UnsupportedByBackend;
    }
    static_files.openRoots(server.mounts, io) catch |err| {
        server.markStopped(io);
        return err;
    };
    // The stop runs in a task of its own: `requestStop` only wakes it. It
    // starts first, so that a stop requested while the backend starts is
    // not lost.
    server.lifecycle = lifecycle: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :lifecycle io.concurrent(runLifecycle, .{ server, io }) catch |err| {
            server.markStopped(io);
            return err;
        };
    };
    server.backend.start(io, flow.handler(server)) catch |err| {
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
        // A stop requested while the backend started: straight to draining.
        server.state_value.store(if (server.stop_requested) .draining else .running, .release);
    }
    server.start_done.set(io);
}

/// Whether the backend has every capability the routes need; logs the
/// route that needs one it lacks.
fn backendCanServe(server: *const Server) bool {
    const can = server.backend.capabilities();
    if (server.needs.flush) |index| if (!can.flush) {
        const info = server.routes[index].info;
        log.warn("{s}.{s} (GET {s}) is an SSE route, which needs a backend with flush; this backend has none", .{ info.controller, info.handler, info.pattern });
        return false;
    };
    if (server.needs.static_mounts > 0 and !can.streaming_response) {
        log.warn("static files need a backend with streaming_response; this backend has none", .{});
        return false;
    }
    return true;
}

/// Waits until the server has stopped; `error.InvalidState` before
/// `start`. Canceling the wait does not stop the server.
pub fn wait(server: *Server, io: std.Io) WaitError!void {
    if (server.state_value.load(.acquire) == .configured) return error.InvalidState;
    try server.wait_event.wait(io);
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
/// get `.shutdown_grace` to end, those that outlive it are canceled without
/// a response or cut, and the server stops.
pub fn requestStop(server: *Server, io: std.Io) void {
    server.mutex.lockUncancelable(io);
    defer server.mutex.unlock(io);
    switch (server.state_value.load(.monotonic)) {
        .configured => {
            server.state_value.store(.stopped, .release);
            server.wait_event.set(io);
            server.shutdown_event.set(io);
            server.grace_over.set(io);
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

/// `requestStop` and a wait for the stop. `error.ShutdownTimeout` when
/// requests did not end within `.shutdown_grace` and, after they were
/// canceled, `.finish_timeout` for their `onFinish` phases and one second
/// more (a handler that ignores its cancelation): the server stays in
/// `draining` until they end. Treat it as fatal and end the process;
/// `deinit` would wait for such requests without a limit.
pub fn shutdown(server: *Server, io: std.Io) ShutdownError!void {
    server.requestStop(io);
    try server.grace_over.wait(io);
    const budget: Duration = .{ .nanoseconds = cancel_budget.nanoseconds +| server.settings.finish_timeout.nanoseconds };
    waiting.untilSet(&server.shutdown_event, io, .after(std.Io.Clock.awake.now(io), budget)) catch |err| switch (err) {
        error.Timeout => return error.ShutdownTimeout,
        error.Canceled => |e| return e,
    };
}

/// How long the requests canceled at the end of a stop's grace have to
/// end, past the time of their `onFinish` phases, before `shutdown` gives
/// up on them.
const cancel_budget: Duration = .fromSeconds(1);

/// Running, and the backend takes requests. Thread-safe; for health
/// checks.
pub fn isReady(server: *const Server) bool {
    return server.state() == .running and server.backend.isReady();
}

/// The state now. Thread-safe; for health checks.
pub fn state(server: *const Server) State {
    return server.state_value.load(.acquire);
}

/// Stops the server if it runs, waits for the stop and frees the tables.
/// No other task may still be in `wait`, `run` or `shutdown`.
pub fn deinit(server: *Server, io: std.Io) void {
    // No cancelation point: a cancelation request of the caller stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server.requestStop(io);
    server.joinLifecycle(io);
    static_files.closeRoots(server.mounts, io);
    static_files.freeMounts(server.gpa, server.mounts);
    freeSettings(server.gpa, server.settings);
    server.trust.deinit(server.gpa);
    for (server.routes) |r| server.gpa.free(r.info.pattern);
    server.gpa.free(server.routes);
    server.gpa.free(server.links);
    server.gpa.free(server.prefix);
    server.* = undefined;
}

fn markStopped(server: *Server, io: std.Io) void {
    {
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        server.state_value.store(.stopped, .release);
    }
    server.wait_event.set(io);
    server.shutdown_event.set(io);
    server.grace_over.set(io);
}

fn joinLifecycle(server: *Server, io: std.Io) void {
    const future = if (server.lifecycle) |*future| future else return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    future.await(io);
    server.lifecycle = null;
}

/// The lifecycle task: waits for a stop and leads it. The backend takes no
/// new requests and the SSE streams are closed at once; the requests at
/// work, and the streams that still send what was published before, get
/// `.shutdown_grace` to end; then the backend cancels what still runs (a
/// request it cancels ends without a response, a stream cut) and the server
/// stops once every task of the backend has ended.
fn runLifecycle(server: *Server, io: std.Io) void {
    // Nothing cancels this task, and its waits are no cancelation points.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    server.stop_event.waitUncancelable(io);
    server.start_done.waitUncancelable(io);
    if (server.rollback) return;
    const grace_end: core.Deadline = .after(std.Io.Clock.awake.now(io), server.settings.shutdown_grace);
    server.backend.stopAccepting(io);
    flow.closeStreams(server, io);
    server.waitIdle(io, grace_end);
    server.grace_over.set(io);
    server.backend.cancelAll(io);
    server.backend.wait(io);
    server.markStopped(io);
}

/// Waits until no request is at work and no stream is open, or `deadline`
/// passes: the stop has closed the streams, which end once they have sent
/// what was published before. Only the lifecycle task calls it.
fn waitIdle(server: *Server, io: std.Io, deadline: core.Deadline) void {
    while (true) {
        server.idle.reset();
        // Read-modify-writes, not loads: they order the reset before the
        // `set` of the request or the stream that drops its count last. A
        // plain load may read the count from before that while the reset
        // lands after its `set`, and the stop would sleep through it.
        if (server.in_flight.fetchAdd(0, .acq_rel) == 0 and server.streams.fetchAdd(0, .acq_rel) == 0) return;
        waiting.untilSet(&server.idle, io, deadline) catch |err| switch (err) {
            error.Timeout => return,
            // The lifecycle task waits with cancelation blocked.
            error.Canceled => unreachable,
        };
    }
}

/// "" or "/api", "/api/v2": what the router compares, segment by segment,
/// with the decoded segments of a path; a mount of `.static` too.
pub fn validPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix[0] != '/') return false;
    var it = std.mem.splitScalar(u8, prefix[1..], '/');
    while (it.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
        for (s) |c| {
            if (c < 0x21 or c > 0x7e or std.mem.findScalar(u8, "%?#{}", c) != null) return false;
        }
    }
    return true;
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
    var server = init(testing.allocator, .{ .backend = backend.backend(), .prefix = config_prefix, .controllers = .{ &users, &health } }) catch |err| {
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
    try testing.expectEqual(want.len, server.routes.len);
    for (want, server.routes) |w, r| {
        try testing.expectEqual(w[0], r.info.method);
        try testing.expectEqualStrings(w[1], r.info.pattern);
        try testing.expectEqualStrings(w[2], r.info.controller);
        try testing.expectEqualStrings(w[3], r.info.handler);
    }
    try testing.expectEqual(@as(*anyopaque, &users), server.routes[1].controller);
    try testing.expectEqual(@as(*anyopaque, &health), server.routes[5].controller);
    try testing.expectEqualStrings("id", server.routes[2].params[0]);
    try testing.expectEqual(route_decls.Timeout{ .after = .fromSeconds(5) }, server.routes[1].timeout);
    try testing.expectEqual(route_decls.Kind.sse, server.routes[3].kind);
    try testing.expect(server.routes[3].on_close != null and server.routes[2].on_close == null);
    try testing.expectEqual(3, server.needs.flush.?);
    try testing.expectEqualStrings("/api", server.prefix);

    // The router of the server takes its prefix.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const values = try arena.alloc([]const u8, server.router.max_params);
    const m = server.router.match(.DELETE, try normalize(arena, "/api/v1/users/42"), values);
    try testing.expectEqualStrings("remove", server.routes[m.found.route].info.handler);
    try testing.expectEqualStrings("42", m.found.params[0]);
    const root = server.router.match(.GET, try normalize(arena, "/api/"), values);
    try testing.expectEqualStrings("root", server.routes[root.found.route].info.handler);
    try testing.expectEqual(routing.Match.not_found, server.router.match(.GET, try normalize(arena, "/v1/users"), values));
}

test "init checks the prefix without I/O" {
    var health: HealthController = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var server = try init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&health} });
    defer server.deinit(testing.io);
    try testing.expectEqualStrings("/", server.routes[0].info.pattern);
    try testing.expectEqualStrings("/health", server.routes[1].info.pattern);
    try testing.expectEqual(State.configured, server.state());

    for ([_][]const u8{ "api", "/api/", "/", "//api", "/a//b", "/a b", "/a%20b", "/./a", "/a/..", "/{x}", "/a?b", "/a#b", "/caf\xc3\xa9" }) |prefix| {
        testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend.backend(), .prefix = prefix, .controllers = .{&health} })) catch |err| {
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
        var server = try init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&health} });
        defer server.deinit(testing.io);
        const s = server.settings;
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
        try testing.expectEqual(0, server.needs.static_mounts);
        try testing.expectEqual(null, server.needs.flush);
    }
    {
        // Nested literals, null, a duration in full, a list from the config.
        const cidrs = try testing.allocator.dupe(u8, "10.1.0.0/16");
        var server = init(testing.allocator, .{
            .backend = backend.backend(),
            .controllers = .{&health},
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
        const s = server.settings;
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
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .max_in_flight = 0 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .max_streams = 0 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .json = .{ .max_depth = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .request_timeout = Duration.zero }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .shutdown_grace = Duration.fromSeconds(-1) }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .finish_timeout = Duration.fromSeconds(-1) }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .backend = backend_value, .controllers = controllers, .trusted_proxies = .{ .list = &.{ "10.0.0.0/8", "10.0.0.0/33" } } }));
}

fn initAndDeinit(gpa: std.mem.Allocator) !void {
    var users: UsersV1Controller = .{};
    var health: HealthController = .{};
    var backend: TestingBackend = .init(gpa);
    defer backend.deinit();
    var server = try init(gpa, .{
        .backend = backend.backend(),
        .prefix = "/api",
        .controllers = .{ &users, &health },
        .trusted_proxies = .{ .list = &.{ "10.0.0.0/8", "fc00::/7" } },
    });
    server.deinit(testing.io);
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
    var server = try init(testing.allocator, .{ .backend = fake.backend(), .controllers = .{ &users, &health } });
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
    var plain = try init(testing.allocator, .{ .backend = fake.backend(), .controllers = .{&health} });
    defer plain.deinit(io);
    try plain.start(io);
    try testing.expectEqual(1, fake.starts);
    try plain.shutdown(io);

    // Static files need streaming_response.
    var no_stream: FakeBackend = .{ .can = .{ .http1 = true, .flush = true } };
    var with_static = try init(testing.allocator, .{ .backend = no_stream.backend(), .controllers = .{&health}, .static = .{static_files.static("/", .{ .root = "public" })} });
    defer with_static.deinit(io);
    try testing.expectEqual(1, with_static.needs.static_mounts);
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
    var server = try init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&gate} });
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
    try server.shutdown(io);
    try testing.expectError(error.InvalidState, server.start(io));
}

test "shutdown and deinit of a server that never started" {
    const io = testing.io;
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    var health: HealthController = .{};
    var server = try init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&health} });
    defer server.deinit(io);
    try server.shutdown(io);
    try testing.expectEqual(State.stopped, server.state());
    try testing.expectError(error.InvalidState, server.start(io));
}
