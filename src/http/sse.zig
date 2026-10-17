//! Server-sent events (design section 12): the route of a stream,
//! `http.sse.get`, and `http.sse.Context`, the context of its methods.
const routes = @import("routes.zig");
const HttpContext = @import("Context.zig");

/// An SSE route, always GET; a HEAD request on its path is not served
/// by it, since HEAD would open a subscription. `opts` may hold
/// `.middleware`, `.heartbeat` (a `std.Io.Duration`) and `.on_close`, the
/// name of the controller's method that runs once when the stream ends:
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
/// opening request until `subscribe`, then the subscription's own.
pub const Context = struct {
    /// Internal: the opening request.
    opening: *HttpContext,
};
