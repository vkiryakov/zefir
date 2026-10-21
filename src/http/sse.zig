//! Server-sent events: a long response of
//! `text/event-stream`, without an upgrade. A route of `http.sse.get`
//! opens a stream, an `http.sse.Manager` keeps the streams by key and
//! publishes to them, and `http.sse.Context` is the context of the route's
//! method and of its `.on_close`.
//!
//! ```zig
//! .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
//!
//! // An ordinary request until subscribe: an error here is an ordinary 4xx or 5xx.
//! pub fn events(self: *TodosV1Controller, ctx: *http.sse.Context) !void {
//!     _ = try self.live.subscribe(ctx, owner(ctx)); // returns at once; the stream lives on
//! }
//!
//! // Once the stream has ended: the client left, close(key), the queue overflowed or the server stopped.
//! pub fn eventsClosed(self: *TodosV1Controller, ctx: *http.sse.Context) void { ... }
//! ```
//!
//! The server's middleware and the route's run once, for the request that
//! opens the stream: `run` before the handler, `onResponse` before the head
//! of the stream, `onFinish` when the stream has ended. Streams count in
//! the server's `.max_streams`, not in `.max_in_flight`, and the deadline
//! of a request does not apply to them. A stop of the server closes them:
//! each sends what was published to it before, within `.shutdown_grace`,
//! then ends, and its client connects to another instance.
const std = @import("std");
const core = @import("core");
const v = @import("validator");
const routes = @import("routes.zig");
const HttpContext = @import("Context.zig");

pub const Manager = @import("sse/Manager.zig");
pub const ManagerOptions = Manager.Options;
pub const SubscriptionId = Manager.SubscriptionId;
pub const SubscribeError = Manager.SubscribeError;

/// An SSE route, always GET; a HEAD request on its path is not served
/// by it, since HEAD would open a subscription. `opts` may hold the input
/// of the handler, which `ctx.input` reads at once: `.path`, `.query`,
/// `.headers` and `.cookies` (DTOs, as for `http.get`; a stream has no
/// body); `.middleware`, `.heartbeat` (a `std.Io.Duration`: a comment
/// `: ping` goes out when nothing else did for that long) and
/// `.on_close`, the name of the controller's method that runs once when
/// the stream ends:
///
/// ```zig
/// .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
/// ```
///
/// The handler is `pub fn events(self: *C, ctx: *http.sse.Context) !void`,
/// `.on_close` names `pub fn eventsClosed(self: *C, ctx: *http.sse.Context) void`.
pub fn get(comptime path: []const u8, comptime opts: anytype) type {
    return routes.Route(.GET, .sse, path, opts);
}

/// The context of an SSE route's method and of its `.on_close`: the
/// methods of `http.Context` that write no response, and `lastEventId`.
/// The head of the stream is the business of `subscribe`, so there is no
/// `response`, and no `json`, `form` or `body`. Strings it gives live
/// until the stream has ended and its `onFinish` phases have run.
pub const Context = struct {
    /// The request that opened the stream: its method, path, headers,
    /// cookies and client.
    request: *HttpContext.Request,
    /// The values that middleware put for the request.
    locals: *HttpContext.Locals,
    /// Internal to the server.
    internal: Internal,

    pub const Internal = struct {
        /// The context of the request that opened the stream.
        http: *HttpContext,
        /// In `.on_close`: the subscription's context.
        operation: ?core.Context = null,
        /// The route's method runs in `opening`, `.on_close` in `closing`.
        phase: enum { opening, closing } = .opening,
    };

    /// The `std.Io` of the stream, for every wait and every I/O.
    pub fn io(ctx: *const Context) std.Io {
        return ctx.internal.http.io();
    }

    /// In the route's method, the request's `core.Context`: its trace, its
    /// deadline and its token, as `http.Context.operation` gives them. In
    /// `.on_close`, the subscription's own: the same trace, no deadline,
    /// and a token of its own, which is canceled once `.on_close` returns.
    pub fn operation(ctx: *const Context) core.Context {
        return ctx.internal.operation orelse ctx.internal.http.operation();
    }

    /// The request's arena, which lives until the stream has ended.
    pub fn allocator(ctx: *const Context) std.mem.Allocator {
        return ctx.internal.http.allocator();
    }

    /// Now on the clock of core's deadlines (`std.Io.Clock.awake`).
    pub fn now(ctx: *const Context) std.Io.Timestamp {
        return ctx.internal.http.now();
    }

    /// The id of the request that opened the stream.
    pub fn requestId(ctx: *const Context) []const u8 {
        return ctx.internal.http.requestId();
    }

    /// The id of its trace: 32 lowercase hex digits.
    pub fn traceId(ctx: *const Context) []const u8 {
        return ctx.internal.http.traceId();
    }

    /// The route of the stream: its method, pattern, controller and
    /// handler.
    pub fn route(ctx: *const Context) ?HttpContext.RouteInfo {
        return ctx.internal.http.route();
    }

    /// The value of type `T` that a middleware put into `ctx.locals`;
    /// `error.LocalMissing` (500, logged) when none did.
    pub fn local(ctx: *const Context, comptime T: type) error{LocalMissing}!T {
        return ctx.internal.http.local(T);
    }

    /// The parameters of the route as a `T`, as `http.Context.path` reads
    /// them.
    pub fn path(ctx: *Context, comptime T: type) (HttpContext.ExtractError || v.TransformError(T))!T {
        return ctx.internal.http.path(T);
    }

    /// The query string as a `T`, as `http.Context.query` reads it.
    pub fn query(ctx: *Context, comptime T: type) (HttpContext.ExtractError || v.TransformError(T))!T {
        return ctx.internal.http.query(T);
    }

    /// The request's headers as a `T`, as `http.Context.headers` reads
    /// them.
    pub fn headers(ctx: *Context, comptime T: type) (HttpContext.ExtractError || v.TransformError(T))!T {
        return ctx.internal.http.headers(T);
    }

    /// The request's cookies as a `T`, as `http.Context.cookies` reads
    /// them: a browser's `EventSource` sends no `Authorization`, so its
    /// session comes in a cookie.
    pub fn cookies(ctx: *Context, comptime T: type) (HttpContext.ExtractError || v.TransformError(T))!T {
        return ctx.internal.http.cookies(T);
    }

    /// The `Last-Event-ID` a client sends when it reconnects: the `id` of
    /// the last event it got; null when it sent none. The server does not
    /// replay what the client missed: the stream goes on from now.
    pub fn lastEventId(ctx: *const Context) ?[]const u8 {
        return ctx.request.header("last-event-id");
    }
};

test {
    _ = @import("sse/format.zig");
    _ = @import("sse/Subscription.zig");
    _ = @import("sse/Manager.zig");
    _ = @import("sse/tests.zig");
}
