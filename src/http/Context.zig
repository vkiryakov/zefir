//! The context of one request (design section 6), as `*http.Context`:
//! what a handler, a middleware and the error handler see.
const routes = @import("routes.zig");

/// The route a request matched.
pub const RouteInfo = routes.RouteInfo;
