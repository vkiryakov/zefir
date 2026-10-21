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
//! The guide, src/http/examples/README.md, builds a whole service step by
//! step: controllers and routes, the input and the output by `field_rules`,
//! responses, the error handler and its strict check, middleware of the
//! application on three levels, static files, server-sent events, tests on
//! `http.testing`, limits and timeouts, and a graceful stop on zio.

const route_decls = @import("routes.zig");

const errors = @import("errors.zig");
const dto = @import("dto.zig");
const middleware = @import("middleware.zig");
const static_files = @import("static.zig");
const describe_file = @import("describe.zig");

pub const Server = @import("Server.zig");
pub const Backend = @import("Backend.zig");
pub const Context = @import("Context.zig");
pub const sse = @import("sse.zig");
pub const native = @import("native.zig");
pub const testing = @import("testing.zig");

pub const Json = dto.Json;
pub const UnknownFields = dto.UnknownFields;
/// Where a response is: `uncommitted`, `committed`
/// once its head has gone to the client, then `finished`.
pub const ResponseState = Context.Response.State;
/// A violation of the input: a field of the wrong type, missing or unknown
/// (`http.invalid_type`, `http.missing_field`, `http.unknown_field`), or a
/// rule of the validator; the field under its outside name.
pub const Violation = @import("validator").Violation;
pub const RouteInfo = route_decls.RouteInfo;
/// What a route serves: `.rest`, a request and its response, or `.sse`, a
/// stream.
pub const RouteKind = route_decls.Kind;
/// A status that a route declares in `.responses`, as its type keeps it
/// in `responses`.
pub const RouteResponse = route_decls.RouteResponse;
/// What `ctx.input(R)` gives: the input that the route `R` declares.
pub const Input = route_decls.Input;
pub const TrustedProxies = Server.TrustedProxies;

// Errors.
pub const Error = errors.Error;
pub const ErrorResponse = errors.ErrorResponse;
pub const ErrorAction = errors.ErrorAction;
pub const Problem = errors.Problem;
pub const defaultStatus = errors.defaultStatus;
pub const defaultCode = errors.defaultCode;
pub const defaultTitle = errors.defaultTitle;

// Middleware: the mechanism; the middleware are the application's.
pub const MiddlewareResult = middleware.MiddlewareResult;
pub const Outcome = middleware.Outcome;
pub const onResponse = middleware.onResponse;
pub const onFinish = middleware.onFinish;

// Static files: `.static = .{ http.static("/", .{ .root = "public" }) }`.
pub const static = static_files.static;
pub const Static = static_files.Static;
pub const StaticOptions = static_files.StaticOptions;

// The server described at compile time, for a generator of documents.
pub const describe = describe_file.describe;
pub const Description = describe_file.Description;
pub const RouteDescription = describe_file.RouteDescription;
pub const ChainElement = describe_file.ChainElement;

pub const routes = route_decls.routes;
pub const get = route_decls.get;
pub const post = route_decls.post;
pub const put = route_decls.put;
pub const patch = route_decls.patch;
pub const delete = route_decls.delete;
pub const head = route_decls.head;
pub const options = route_decls.options;

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
    _ = @import("describe.zig");
    _ = @import("check.zig");
    _ = @import("Server.zig");
    _ = @import("errors.zig");
    _ = @import("strict.zig");
    _ = @import("ids.zig");
    _ = @import("Request.zig");
    _ = @import("Context.zig");
    _ = @import("Locals.zig");
    _ = @import("middleware.zig");
    _ = @import("proxies.zig");
    _ = @import("input/strings.zig");
    _ = @import("input/urlencoded.zig");
    _ = @import("input/cookies.zig");
    _ = @import("input/violations.zig");
    _ = @import("input/json_in.zig");
    _ = @import("output/json_out.zig");
    _ = @import("Response.zig");
    _ = @import("mime.zig");
    _ = @import("static.zig");
    _ = @import("flow.zig");
    _ = @import("wait.zig");
    _ = @import("testing.zig");
    _ = @import("native.zig");
    _ = @import("sse.zig");
}
