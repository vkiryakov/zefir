//! The context of one request (design section 6), as `*http.Context`:
//! what a handler, a middleware and the error handler see. The request is
//! `ctx.request`, the response `ctx.response`. Strings it gives live in
//! the request's arena until the request has ended; to keep one longer,
//! copy it.
//!
//! ```zig
//! pub fn get(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) {
//!     const todo = try self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), id);
//!     return .{ .value = .from(todo) };
//! }
//! ```
const std = @import("std");
const core = @import("core");
const routes = @import("routes.zig");

const Context = @This();

/// The route a request matched.
pub const RouteInfo = routes.RouteInfo;
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");

request: Request,
response: Response,
/// Internal to the server.
internal: Internal,

pub const Internal = struct {
    io: std.Io,
    operation: core.Context,
    arena: std.mem.Allocator,
    request_id: [32]u8,
    trace_id: [32]u8,
    route: ?RouteInfo = null,
    /// The values of the route's parameters, in the order of its pattern.
    params: []const []const u8 = &.{},
};

/// The `std.Io` of the request, for every wait and every I/O: a database,
/// an HTTP client, the clock.
pub fn io(ctx: *const Context) std.Io {
    return ctx.internal.io;
}

/// The request as a `core.Context`, by value: its trace, its deadline (the
/// route's `.timeout` or the server's `.request_timeout`) and its token,
/// which the server cancels when the client has gone or a stop's grace is
/// over. Pass it to the services the handler calls; `check(ctx.now())`
/// gives `error.DeadlineExceeded` or `error.Cancelled`.
pub fn operation(ctx: *const Context) core.Context {
    return ctx.internal.operation;
}

/// The request's arena: what it gives is freed when the request has
/// ended, without a `free`.
pub fn allocator(ctx: *const Context) std.mem.Allocator {
    return ctx.internal.arena;
}

/// Now on the clock of core's deadlines (`std.Io.Clock.awake`), for
/// `ctx.operation().check(ctx.now())` and for measuring.
pub fn now(ctx: *const Context) std.Io.Timestamp {
    return std.Io.Clock.awake.now(ctx.internal.io);
}

/// The id of the request: 32 lowercase hex digits.
pub fn requestId(ctx: *const Context) []const u8 {
    return &ctx.internal.request_id;
}

/// The id of the request's trace: 32 lowercase hex digits, the client's
/// from `traceparent` or a new one.
pub fn traceId(ctx: *const Context) []const u8 {
    return &ctx.internal.trace_id;
}

/// The route the request matched: its method, pattern, controller and
/// handler; null before the route is chosen.
pub fn route(ctx: *const Context) ?RouteInfo {
    return ctx.internal.route;
}
