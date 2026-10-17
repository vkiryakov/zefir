//! zefir-http: the web framework of zefir. An `http.Server` serves the
//! controllers of an application, whose routes are known when it is built:
//! a strict HTTP/1.1 parser of its own, the request input and output read
//! from the `field_rules` of zefir-validator, middleware of the
//! application, one error handler, static files, streamed responses and
//! SSE. The network backend runs on `std.Io` (zio in production), and an
//! in-memory backend serves the same server to tests.
//!
//! A controller declares its routes, and the compiler checks them where
//! the controller is passed to `http.Server.init`:
//!
//! ```zig
//! const TodosV1Controller = @This();
//!
//! pub const http_routes = http.routes(.{
//!     .prefix = "/v1/todos",
//!     .methods = .{
//!         .get = http.get("/{id}", .{}),
//!         .events = http.sse.get("/events", .{ .on_close = .eventsClosed }),
//!     },
//! });
//!
//! pub fn get(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) { ... }
//! ```
//!
//! Status: in progress. So far the module holds its HTTP/1.1 parser
//! (h1/, internal), the routes of controllers (their declarations, the
//! checks the compiler makes of them, the router and the normalization of
//! paths), the server with its lifecycle and the path of a request (each
//! request in a task of its own, with its deadline, the client that
//! leaves, the stop and the limit of requests at work), the backend in
//! memory of `http.testing`, and the network backend of `http.native`
//! (connections, heads, responses, keep-alive and the watcher; request
//! bodies come next); the rest of the API comes with the next commits.

const std = @import("std");
const route_decls = @import("routes.zig");

const errors = @import("errors.zig");
const dto = @import("dto.zig");

pub const Server = @import("Server.zig");
pub const Backend = @import("Backend.zig");
pub const Context = @import("Context.zig");
pub const sse = @import("sse.zig");
pub const native = @import("native.zig");
pub const testing = @import("testing.zig");

pub const Json = dto.Json;
pub const UnknownFields = dto.UnknownFields;
pub const RouteInfo = route_decls.RouteInfo;
pub const TrustedProxies = Server.TrustedProxies;

// Errors.
pub const Error = errors.Error;
pub const Problem = errors.Problem;
pub const defaultStatus = errors.defaultStatus;
pub const defaultCode = errors.defaultCode;
pub const defaultTitle = errors.defaultTitle;

pub const routes = route_decls.routes;
pub const get = route_decls.get;
pub const post = route_decls.post;
pub const put = route_decls.put;
pub const patch = route_decls.patch;
pub const delete = route_decls.delete;
pub const head = route_decls.head;
pub const options = route_decls.options;

test "zefir-http is wired into the build" {
    try std.testing.expect(true);
}

test {
    _ = @import("h1/head.zig");
    _ = @import("h1/chunked.zig");
    _ = @import("h1/fuzz.zig");
    _ = @import("h1/date.zig");
    _ = @import("h1/response.zig");
    _ = @import("dto.zig");
    _ = @import("path.zig");
    _ = @import("router.zig");
    _ = @import("plan.zig");
    _ = @import("Server.zig");
    _ = @import("errors.zig");
    _ = @import("ids.zig");
    _ = @import("Request.zig");
    _ = @import("Response.zig");
    _ = @import("flow.zig");
    _ = @import("wait.zig");
    _ = @import("testing.zig");
    _ = @import("native.zig");
}
