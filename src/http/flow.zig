//! One request through the server (design sections 5, 8, 11, 14 and 17),
//! on the task the backend runs it on, the connection's. The request gets
//! its context: its trace and id, its deadline (the route's `.timeout`, or
//! the server's `.request_timeout`) and a cancelation token of its own.
//! Then two tasks race in an `Io.Select`: the request (the route, the
//! handler, the response it writes) and its guard, which waits for the
//! deadline and, once the body has been read, watches the connection for a
//! client that leaves. Whichever ends first decides; the server keeps the
//! reason itself, since a canceled task sees only `error.Canceled`:
//!
//! - the request ended: its response. A handler that wrote nothing
//!   answers 204, an `http.Json(T)` its value, an error
//!   `application/problem+json` with the status of `http.defaultStatus`;
//! - the deadline passed: the request is canceled and the answer is 504
//!   (`error.RequestTimeout`). The deadline does not cancel the token, so
//!   `ctx.operation().check(now)` reports `DeadlineExceeded`;
//! - the client left, or the stop canceled the connection after its
//!   grace: the token and the request are canceled, no response goes out.
//!
//! A body that did not arrive whole because it stalled past the backend's
//! body timeout or broke its chunked framing is answered as the backend
//! answers a broken head: 408 or 400 as short text, and the connection
//! closes after it; the error handler has no part in it.
//!
//! Before any task, a request over `.max_in_flight` gets 503
//! (`error.Overloaded`), and so does one the runtime gives no task for
//! (`error.ConcurrencyUnavailable`). The other task is canceled and waited
//! for before the response goes out, so one request gets exactly one
//! outcome, written once.
const std = @import("std");
const core = @import("core");
const Backend = @import("Backend.zig");
const Exchange = Backend.Exchange;
const Server = @import("Server.zig");
const Context = @import("Context.zig");
const errors = @import("errors.zig");
const ids = @import("ids.zig");
const path = @import("path.zig");
const routing = @import("router.zig");
const Allow = routing.Allow;
const h1 = @import("h1/head.zig");
const response = @import("h1/response.zig");
const waiting = @import("wait.zig");

const log = std.log.scoped(.http);

/// The server as the handler of its backend.
pub fn handler(server: *Server) Backend.Handler {
    return .{ .ptr = server, .serve = serveErased };
}

fn serveErased(ptr: *anyopaque, io: std.Io, exchange: *Exchange) void {
    serve(@ptrCast(@alignCast(ptr)), io, exchange);
}

/// The two tasks of a request and what each returns.
const Task = union(enum) {
    request: anyerror!void,
    guard: Exchange.Watch,
};

/// What ended a request, as the server keeps it.
const Reason = union(enum) {
    /// The request ended, with the handler's result.
    done: anyerror!void,
    deadline,
    client_gone,
    /// The stop canceled the connection's task after its grace.
    shutdown,
};

/// Serves `exchange` to its end: the response sent, or aborted.
pub fn serve(server: *Server, io: std.Io, exchange: *Exchange) void {
    const arena = exchange.arena;
    // Out of memory for the tracestate: a trace of its own.
    const trace = ids.traceOf(io, arena, exchange.fields) catch ids.newTrace(io);
    const target = path.splitTarget(exchange.target);
    // Both live on this task until the request has ended.
    var token: core.CancellationToken = .init;
    var body_done: std.Io.Event = .unset;
    var ctx: Context = .{
        .request = .{
            .method = exchange.method,
            .path = target.path,
            .internal = .{ .exchange = exchange, .io = io, .query = target.query, .body_done = &body_done },
        },
        .response = .{ .internal = .{ .arena = arena } },
        .internal = .{
            .io = io,
            .operation = core.Context.root.withTrace(trace).withCancellation(&token),
            .arena = arena,
            .gpa = server.gpa,
            .request_id = ids.newRequestId(io),
            .trace_id = trace.trace_id.toHex(),
            .max_body_bytes = server.settings.max_body_bytes,
            .max_query_params = server.settings.max_query_params,
            .unknown_fields = server.settings.unknown_fields,
        },
    };
    if (!takeSlot(server)) return respond(&ctx, exchange, error.Overloaded);
    defer releaseSlot(server, io);

    const found = find(server, &ctx);
    const deadline: ?core.Deadline = if (budgetOf(server, found)) |budget| .after(ctx.now(), budget) else null;
    if (deadline) |d| ctx.internal.operation = ctx.internal.operation.withDeadline(d);
    // Without a body, the guard watches the connection at once.
    if (exchange.bodyLength() == 0) body_done.set(io);

    var buffer: [2]Task = undefined;
    var select: std.Io.Select(Task) = .init(io, &buffer);
    // The guard first: without a task for the request, no handler has begun.
    select.concurrent(.guard, guard, .{ io, exchange, deadline, &body_done }) catch
        return unavailable(&ctx, exchange);
    select.concurrent(.request, runRequest, .{ server, &ctx, found }) catch {
        select.cancelDiscard();
        return unavailable(&ctx, exchange);
    };
    var canceled = false;
    const reason: Reason = if (select.await()) |first| switch (first) {
        .request => |result| .{ .done = result },
        .guard => |watch| switch (watch) {
            .deadline => .deadline,
            .client_gone => .client_gone,
        },
    } else |_| reason: {
        canceled = true;
        break :reason .shutdown;
    };
    // A deadline leaves the token alone (design section 17).
    if (reason == .client_gone or reason == .shutdown) token.cancel();
    // Cancels the other task and waits for it: from here on, only this
    // task touches the context.
    select.cancelDiscard();
    switch (reason) {
        .done => |result| respond(&ctx, exchange, result),
        .deadline => respond(&ctx, exchange, error.RequestTimeout),
        .client_gone, .shutdown => exchange.abort(io),
    }
    // The backend sees the stop's cancelation at its next cancelation point.
    if (canceled) io.recancel();
}

/// Takes one of the `.max_in_flight` places, unless all are taken.
fn takeSlot(server: *Server) bool {
    var current = server.in_flight.load(.monotonic);
    while (current < server.settings.max_in_flight) {
        current = server.in_flight.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

fn releaseSlot(server: *Server, io: std.Io) void {
    if (server.in_flight.fetchSub(1, .acq_rel) == 1) server.idle.set(io);
}

/// The runtime gave no task for the request: 503.
fn unavailable(ctx: *Context, exchange: *Exchange) void {
    log.warn("the runtime gave no task for a request; the response is 503 (request {s})", .{ctx.requestId()});
    respond(ctx, exchange, error.ConcurrencyUnavailable);
}

/// What the path comes to, found before any task so that the route's
/// `.timeout` is known: the router's match, or the error of a path the
/// router cannot take.
const Found = union(enum) {
    match: routing.Match,
    failed: anyerror,
};

fn find(server: *Server, ctx: *Context) Found {
    const arena = ctx.internal.arena;
    if (std.mem.eql(u8, ctx.request.path, "*")) {
        // `OPTIONS *` asks about the server, not a path.
        if (ctx.request.method != .OPTIONS) return .{ .failed = error.InvalidRequest };
        return .{ .match = .{ .options = server.router.serverAllow() } };
    }
    const normalized = path.normalize(arena, ctx.request.path) catch |err| return .{ .failed = err };
    const values = arena.alloc([]const u8, server.router.max_params) catch |err| return .{ .failed = err };
    return .{ .match = server.router.match(ctx.request.method, normalized, values) };
}

/// The budget of the request's deadline: the route's `.timeout`, else the
/// server's `.request_timeout`; null for none.
fn budgetOf(server: *const Server, found: Found) ?std.Io.Duration {
    const index = switch (found) {
        .match => |match| switch (match) {
            .found => |f| f.route,
            else => null,
        },
        .failed => null,
    } orelse return server.settings.request_timeout;
    return switch (server.routes[index].timeout) {
        .server => server.settings.request_timeout,
        .none => null,
        .after => |budget| budget,
    };
}

/// The guard of a request: the deadline, and the connection once the body
/// has been read, so that one task at a time reads it. The request's end
/// cancels the guard, and its value is then dropped.
fn guard(io: std.Io, exchange: *Exchange, deadline: ?core.Deadline, body_done: *std.Io.Event) Exchange.Watch {
    if (deadline) |d| {
        waiting.untilSet(body_done, io, d) catch return .deadline;
    } else body_done.wait(io) catch return .deadline;
    return exchange.watch(io, if (deadline) |d| d.toTimeout() else .none);
}

/// The request task: the route and its handler, or the error that answers
/// the request.
fn runRequest(server: *Server, ctx: *Context, found: Found) anyerror!void {
    const match = switch (found) {
        .match => |match| match,
        .failed => |err| return err,
    };
    switch (match) {
        .found => |f| {
            const route = &server.routes[f.route];
            ctx.internal.route = route.info;
            ctx.internal.param_names = route.params;
            ctx.internal.params = f.params;
            ctx.internal.max_body_bytes = route.max_body_bytes orelse server.settings.max_body_bytes;
            return route.handle(route.controller, ctx);
        },
        .method_not_allowed => |allow| {
            try ctx.response.setHeader("allow", allow.header());
            return error.MethodNotAllowed;
        },
        .options => |allow| return answerOptions(ctx, allow),
        .not_found => return error.RouteNotFound,
    }
}

/// The response to `result`: what the handler wrote, or the answer to its
/// error; none for a request canceled.
fn respond(ctx: *Context, exchange: *Exchange, result: anyerror!void) void {
    if (result) {
        const code = ctx.response.internal.code orelse 200;
        if (code < 200 or code > 599) {
            log.warn("{s} set the status {d}, which is not a final status; the response is 500 (request {s})", .{ routeName(ctx), code, ctx.requestId() });
            setProblem(ctx, errors.DefaultErrors.problem(error.Unexpected));
        }
    } else |err| {
        if (errors.isCancellation(err)) return exchange.abort(ctx.internal.io);
        if (err == error.ReadFailed) if (exchange.bodyFailure()) |failure| return answerBodyFailure(ctx, exchange, failure);
        if (errors.defaultStatus(err) == 500)
            log.warn("{s} failed with error.{t}; the response is 500 (request {s})", .{ routeName(ctx), err, ctx.requestId() });
        var problem = errors.DefaultErrors.problem(err);
        if (err == error.ValidationFailed) problem.errors = ctx.violations();
        setProblem(ctx, problem);
    }
    send(ctx, exchange);
}

/// OPTIONS without a route of its own: 204 with `Allow`.
fn answerOptions(ctx: *Context, allow: Allow) Context.Response.HeaderError!void {
    try ctx.response.setHeader("allow", allow.header());
    _ = ctx.response.status(204);
}

/// The answer to a body that did not arrive whole (decision 21): 408 when
/// it stalled past the backend's body timeout, 400 when its framing broke;
/// its reason as short text, the fields of the content gone and the others
/// kept, as `setProblem` does. The backend closes the connection after it.
/// The response is written only here, so nothing of it has gone out yet.
fn answerBodyFailure(ctx: *Context, exchange: *Exchange, failure: Exchange.BodyFailure) void {
    const status: u16 = switch (failure) {
        .timeout => 408,
        .malformed => 400,
    };
    const res = &ctx.response.internal;
    dropContentFields(res);
    res.code = status;
    res.content_type = "text/plain; charset=utf-8";
    res.body = response.reason(status);
    send(ctx, exchange);
}

/// Replaces the response with `problem` as problem+json. The fields of
/// the content go with the old body; the others stay (`Allow`, those of
/// the application).
fn setProblem(ctx: *Context, problem: errors.Problem) void {
    const res = &ctx.response.internal;
    dropContentFields(res);
    res.code = problem.status;
    res.content_type = "application/problem+json";
    res.body = std.json.Stringify.valueAlloc(res.arena, problem, .{ .emit_null_optional_fields = false }) catch internal: {
        // Out of memory: the problem of every 500, known at compile time.
        res.code = 500;
        break :internal internal_problem;
    };
}

const internal_problem = "{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500,\"code\":\"internal\",\"errors\":[]}";

fn dropContentFields(res: *Context.Response.Internal) void {
    var kept: usize = 0;
    for (res.headers.items) |f| {
        if (isContentField(f.name)) continue;
        res.headers.items[kept] = f;
        kept += 1;
    }
    res.headers.shrinkRetainingCapacity(kept);
}

fn isContentField(name: []const u8) bool {
    for ([_][]const u8{ "content-length", "content-encoding", "content-disposition" }) |content| {
        if (std.ascii.eqlIgnoreCase(name, content)) return true;
    }
    return false;
}

/// Sends the response: its status (204 without a body, 200 with one,
/// unless the handler set it), its fields with `Content-Type`, and its
/// body; none for HEAD, 204 and 304. A write that fails aborts it.
fn send(ctx: *Context, exchange: *Exchange) void {
    const io = ctx.internal.io;
    const res = &ctx.response.internal;
    const code = res.code orelse if (res.body != null) @as(u16, 200) else 204;
    const fields = fieldsOf(res) catch {
        log.warn("{s}: out of memory for the fields of the response (request {s})", .{ routeName(ctx), ctx.requestId() });
        exchange.abort(io);
        return;
    };
    const body = res.body orelse "";
    const has_body = code != 204 and code != 304;
    const kind: Exchange.BodyKind = if (has_body) .{ .length = body.len } else .none;
    write(io, exchange, code, fields, kind, if (has_body and ctx.request.method != .HEAD) body else "") catch
        exchange.abort(io);
}

fn write(io: std.Io, exchange: *Exchange, code: u16, fields: []const h1.Field, kind: Exchange.BodyKind, body: []const u8) Exchange.WriteError!void {
    try exchange.writeHead(io, code, fields, kind);
    if (body.len > 0) try exchange.writeBody(io, body);
    try exchange.finish(io);
}

/// The fields of the response, `Content-Type` first when there is one.
fn fieldsOf(res: *const Context.Response.Internal) error{OutOfMemory}![]const h1.Field {
    const content_type = res.content_type orelse return res.headers.items;
    const fields = try res.arena.alloc(h1.Field, res.headers.items.len + 1);
    fields[0] = .{ .name = "content-type", .value = content_type };
    @memcpy(fields[1..], res.headers.items);
    return fields;
}

/// The route for a line of the log: its controller and handler, or the
/// method alone before a route; never the path, which may carry data.
fn routeName(ctx: *const Context) []const u8 {
    const info = ctx.internal.route orelse return @tagName(ctx.request.method);
    return std.fmt.allocPrint(ctx.internal.arena, "{s}.{s} ({t} {s})", .{ info.controller, info.handler, info.method, info.pattern }) catch info.handler;
}

const testing = std.testing;
const TestingBackend = @import("testing/Backend.zig");
const routes = @import("routes.zig");
const Json = @import("dto.zig").Json;

const Todo = struct { id: u64, title: []const u8 };

const TodosV1Controller = struct {
    seen_route: ?routes.RouteInfo = null,
    seen_now: ?std.Io.Timestamp = null,
    seen_operation: ?core.Context = null,

    pub const http_routes = routes.routes(.{
        .prefix = "/v1/todos",
        .methods = .{
            .list = routes.get("", .{}),
            .get = routes.get("/{id}", .{}),
            .create = routes.post("", .{}),
            .remove = routes.delete("/{id}", .{}),
            .accepted = routes.post("/{id}/archive", .{}),
            .page = routes.get("/{id}/page", .{}),
            .fail = routes.get("/{id}/fail", .{}),
            .cancel = routes.get("/{id}/cancel", .{}),
            .bad_status = routes.get("/{id}/bad-status", .{}),
            .split = routes.get("/{id}/split", .{}),
            .negotiate = routes.get("/{id}/negotiate", .{}),
        },
    });

    pub fn list(self: *TodosV1Controller, ctx: *Context) !void {
        self.seen_route = ctx.route();
        self.seen_now = ctx.now();
        self.seen_operation = ctx.operation();
        try ctx.response.setHeader("x-request-id", ctx.requestId());
        try ctx.response.setHeader("x-trace-id", ctx.traceId());
    }
    pub fn get(_: *TodosV1Controller, _: *Context) !Json(Todo) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }
    pub fn create(_: *TodosV1Controller, _: *Context) !Json(Todo) {
        return .{ .value = .{ .id = 2, .title = "Buy bread" }, .status = 201 };
    }
    pub fn remove(_: *TodosV1Controller, _: *Context) void {}
    pub fn accepted(_: *TodosV1Controller, ctx: *Context) !void {
        _ = ctx.response.status(202);
    }
    pub fn page(_: *TodosV1Controller, ctx: *Context) !void {
        try ctx.response.status(203).html("<p>todo</p>");
    }
    pub fn fail(_: *TodosV1Controller, ctx: *Context) error{ TodoNotFound, InvalidHeaderValue, ReservedHeader, OutOfMemory }!void {
        try ctx.response.setHeader("x-kept", "yes");
        try ctx.response.setHeader("content-disposition", "attachment; filename=\"todo.txt\"");
        try ctx.response.text("half a body");
        return error.TodoNotFound;
    }
    pub fn cancel(_: *TodosV1Controller, _: *Context) !void {
        return error.Canceled;
    }
    pub fn bad_status(_: *TodosV1Controller, ctx: *Context) !void {
        _ = ctx.response.status(100);
    }
    pub fn split(_: *TodosV1Controller, ctx: *Context) !void {
        try ctx.response.setHeader("x-name", ctx.request.header("x-name") orelse "");
    }
    pub fn negotiate(_: *TodosV1Controller, ctx: *Context) !void {
        if (ctx.request.accepts("text/html")) return ctx.response.html("<p>todo</p>");
        return ctx.response.text("todo");
    }
};

const Fixture = struct {
    todos: TodosV1Controller = .{},
    backend: TestingBackend,
    server: Server = undefined,

    fn start(f: *Fixture, io: std.Io) !void {
        f.backend = .init(testing.allocator);
        f.server = try .init(testing.allocator, .{ .backend = f.backend.backend(), .prefix = "/api", .controllers = .{&f.todos} });
        f.server.start(io) catch |err| {
            f.server.deinit(io);
            return err;
        };
    }

    fn stop(f: *Fixture, io: std.Io) void {
        f.server.deinit(io);
        f.backend.deinit();
    }

    fn request(f: *Fixture, io: std.Io, method: std.http.Method, target: []const u8) !TestingBackend.Response {
        return f.backend.request(io, .{ .method = method, .target = target });
    }
};

test "a !void handler is 204; http.Json is 200 or its status" {
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);

    // Nothing written: 204 without a body and without Content-Length.
    var none = try f.request(io, .GET, "/api/v1/todos");
    defer none.deinit();
    try testing.expectEqual(204, none.status);
    try testing.expectEqual(null, none.header("content-length"));
    try testing.expectEqualStrings("", none.body);
    try testing.expect(!none.aborted);

    // A handler without an error set answers the same.
    var removed = try f.request(io, .DELETE, "/api/v1/todos/7");
    defer removed.deinit();
    try testing.expectEqual(204, removed.status);

    var got = try f.request(io, .GET, "/api/v1/todos/1");
    defer got.deinit();
    try testing.expectEqual(200, got.status);
    try testing.expectEqualStrings("application/json", got.header("content-type").?);
    try testing.expectEqualStrings("{\"id\":1,\"title\":\"Buy milk\"}", got.body);
    try testing.expectEqualStrings("27", got.header("content-length").?);

    var created = try f.request(io, .POST, "/api/v1/todos");
    defer created.deinit();
    try testing.expectEqual(201, created.status);
    try testing.expectEqualStrings("{\"id\":2,\"title\":\"Buy bread\"}", created.body);

    // A status without a body: that status and an empty body; a status
    // with a body: both.
    var archived = try f.request(io, .POST, "/api/v1/todos/7/archive");
    defer archived.deinit();
    try testing.expectEqual(202, archived.status);
    try testing.expectEqualStrings("0", archived.header("content-length").?);
    var page = try f.request(io, .GET, "/api/v1/todos/7/page");
    defer page.deinit();
    try testing.expectEqual(203, page.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", page.header("content-type").?);
    try testing.expectEqualStrings("<p>todo</p>", page.body);
}

test "404, 405 with Allow, HEAD without a body, OPTIONS 204 with Allow" {
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);

    var missing = try f.request(io, .GET, "/api/v1/nothing");
    defer missing.deinit();
    try testing.expectEqual(404, missing.status);
    try testing.expectEqualStrings("application/problem+json", missing.header("content-type").?);
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404,\"code\":\"not_found\",\"errors\":[]}", missing.body);

    var wrong = try f.request(io, .PUT, "/api/v1/todos/1");
    defer wrong.deinit();
    try testing.expectEqual(405, wrong.status);
    try testing.expectEqualStrings("GET, HEAD, DELETE, OPTIONS", wrong.header("allow").?);
    try testing.expectEqualStrings("method_not_allowed", (try std.json.parseFromSliceLeaky(struct { code: []const u8 }, wrong.arena.allocator(), wrong.body, .{ .ignore_unknown_fields = true })).code);

    // HEAD: the GET handler, its fields and the length of its body, no body.
    var head = try f.request(io, .HEAD, "/api/v1/todos/1");
    defer head.deinit();
    try testing.expectEqual(200, head.status);
    try testing.expectEqualStrings("application/json", head.header("content-type").?);
    try testing.expectEqualStrings("27", head.header("content-length").?);
    try testing.expectEqualStrings("", head.body);
    try testing.expect(!head.aborted);
    // HEAD of a path without a route is a 404 without a body.
    var head_missing = try f.request(io, .HEAD, "/api/v1/nothing");
    defer head_missing.deinit();
    try testing.expectEqual(404, head_missing.status);
    try testing.expectEqualStrings("", head_missing.body);

    var options = try f.request(io, .OPTIONS, "/api/v1/todos/1");
    defer options.deinit();
    try testing.expectEqual(204, options.status);
    try testing.expectEqualStrings("GET, HEAD, DELETE, OPTIONS", options.header("allow").?);
    try testing.expectEqual(null, options.header("content-length"));
    var server_options = try f.request(io, .OPTIONS, "*");
    defer server_options.deinit();
    try testing.expectEqual(204, server_options.status);
    try testing.expectEqualStrings("GET, HEAD, POST, DELETE, OPTIONS", server_options.header("allow").?);

    // A path the router cannot take: 400; `*` only for OPTIONS.
    for ([_][]const u8{ "/api/v1/todos/%zz", "/api/v1/todos/%C3%28", "*" }) |target| {
        var bad = try f.request(io, .GET, target);
        defer bad.deinit();
        try testing.expectEqual(400, bad.status);
        try testing.expectEqualStrings("application/problem+json", bad.header("content-type").?);
    }
    // The query and an absolute target are not part of the path.
    var absolute = try f.request(io, .GET, "http://example.com/api/v1/todos/1?full=1");
    defer absolute.deinit();
    try testing.expectEqual(200, absolute.status);
}

test "an error is problem+json: the fields of the content go, the others stay" {
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);
    const level = testing.log_level;
    testing.log_level = .err; // a 500 is logged as a warning
    defer testing.log_level = level;

    var failed = try f.request(io, .GET, "/api/v1/todos/1/fail");
    defer failed.deinit();
    try testing.expectEqual(500, failed.status);
    try testing.expectEqualStrings("application/problem+json", failed.header("content-type").?);
    try testing.expectEqualStrings("yes", failed.header("x-kept").?);
    try testing.expectEqual(null, failed.header("content-disposition"));
    try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500,\"code\":\"internal\",\"errors\":[]}", failed.body);

    // A status that is not final is a mistake of the handler: 500.
    var bad_status = try f.request(io, .GET, "/api/v1/todos/1/bad-status");
    defer bad_status.deinit();
    try testing.expectEqual(500, bad_status.status);

    // Canceled: no response at all.
    var canceled = try f.request(io, .GET, "/api/v1/todos/1/cancel");
    defer canceled.deinit();
    try testing.expect(canceled.aborted);
    try testing.expectEqual(0, canceled.status);
}

test "the server logs through std.log.scoped(.http) and needs no logger" {
    // No logger is installed here: a 500 goes to std.log under the scope
    // http, and the request gets its answer.
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expect(log == std.log.scoped(.http));

    var failed = try f.request(io, .GET, "/api/v1/todos/1/fail");
    defer failed.deinit();
    try testing.expectEqual(500, failed.status);
}

test "traceparent and the request id reach the handler; ctx.route names the route" {
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);

    const before = std.Io.Clock.awake.now(io);
    var continued = try f.backend.request(io, .{
        .method = .GET,
        .target = "/api/v1/todos",
        .headers = &.{.{ "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }},
    });
    defer continued.deinit();
    const after = std.Io.Clock.awake.now(io);
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", continued.header("x-trace-id").?);
    // ctx.now() is on the awake clock; the operation carries the trace.
    const seen = f.todos.seen_now.?;
    try testing.expect(seen.nanoseconds >= before.nanoseconds and seen.nanoseconds <= after.nanoseconds);
    const op = f.todos.seen_operation.?;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &op.trace.?.trace_id.toHex());
    // The server's span is new.
    try testing.expect(!std.mem.eql(u8, "00f067aa0ba902b7", &op.trace.?.span_id.toHex()));
    // The deadline of the server's .request_timeout, from when the request
    // came; the request's own token (the request has ended: not read).
    const expires = op.deadline.?.expires.nanoseconds;
    try testing.expect(expires >= before.nanoseconds + std.time.ns_per_s * 30 and expires <= after.nanoseconds + std.time.ns_per_s * 30);
    try testing.expect(op.cancellation != null);
    const first_id = continued.header("x-request-id").?;
    try testing.expectEqual(32, first_id.len);
    const route = f.todos.seen_route.?;
    try testing.expectEqual(std.http.Method.GET, route.method);
    try testing.expectEqualStrings("/api/v1/todos", route.pattern);
    try testing.expectEqualStrings("TodosV1Controller", route.controller);
    try testing.expectEqualStrings("list", route.handler);

    var fresh = try f.request(io, .GET, "/api/v1/todos");
    defer fresh.deinit();
    try testing.expect(!std.mem.eql(u8, "4bf92f3577b34da6a3ce929d0e0e4736", fresh.header("x-trace-id").?));
    try testing.expectEqual(32, fresh.header("x-trace-id").?.len);
    try testing.expect(!std.mem.eql(u8, first_id, fresh.header("x-request-id").?));
}

test "through the server: setHeader refuses a value that would split the response; accepts chooses" {
    const io = testing.io;
    var f: Fixture = .{ .backend = undefined };
    try f.start(io);
    defer f.stop(io);
    const level = testing.log_level;
    testing.log_level = .err; // the 500 is logged as a warning
    defer testing.log_level = level;

    var plain = try f.backend.request(io, .{ .method = .GET, .target = "/api/v1/todos/1/split", .headers = &.{.{ "x-name", "ann" }} });
    defer plain.deinit();
    try testing.expectEqual(204, plain.status);
    try testing.expectEqualStrings("ann", plain.header("x-name").?);

    // The client's bytes would start a second header: InvalidHeaderValue, 500.
    var split = try f.backend.request(io, .{ .method = .GET, .target = "/api/v1/todos/1/split", .headers = &.{.{ "x-name", "ann\r\nset-cookie: session=evil" }} });
    defer split.deinit();
    try testing.expectEqual(500, split.status);
    try testing.expectEqual(null, split.header("set-cookie"));
    try testing.expectEqual(null, split.header("x-name"));

    var html = try f.backend.request(io, .{ .method = .GET, .target = "/api/v1/todos/1/negotiate", .headers = &.{.{ "accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8" }} });
    defer html.deinit();
    try testing.expectEqualStrings("text/html; charset=utf-8", html.header("content-type").?);
    var text = try f.backend.request(io, .{ .method = .GET, .target = "/api/v1/todos/1/negotiate", .headers = &.{.{ "accept", "application/json, text/html;q=0" }} });
    defer text.deinit();
    try testing.expectEqualStrings("text/plain; charset=utf-8", text.header("content-type").?);
    var any = try f.request(io, .GET, "/api/v1/todos/1/negotiate");
    defer any.deinit();
    try testing.expectEqualStrings("<p>todo</p>", any.body);
}

const inFlight = @import("testing.zig").inFlight;

/// For the concurrent tests of the module: ends the process with code 4
/// when a test runs past its limit, so that a deadlock fails the run
/// instead of hanging it. `std.process.exit` does not abort.
const Watchdog = struct {
    future: std.Io.Future(void),

    fn start(io: std.Io, name: []const u8) std.Io.ConcurrentError!Watchdog {
        return .{ .future = try io.concurrent(watch, .{ io, name }) };
    }

    fn stop(w: *Watchdog, io: std.Io) void {
        w.future.cancel(io);
    }

    fn watch(io: std.Io, name: []const u8) void {
        io.sleep(.fromSeconds(120), .awake) catch return;
        std.debug.print("test \"{s}\" still runs after 120 s: a deadlock\n", .{name});
        std.process.exit(4);
    }
};

/// Handlers that wait: for deadlines, clients that leave and the limit of
/// requests at work.
const WaitController = struct {
    /// Requests that have entered `gated`.
    entered: std.atomic.Value(u32) = .init(0),
    /// Opens `gated`.
    gate: std.Io.Event = .unset,
    /// Handlers whose work an error ended, and of those the ones whose
    /// operation then reported each error of core.
    canceled: std.atomic.Value(u32) = .init(0),
    deadline_exceeded: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    /// Calls of `edge`, for its spread.
    edges: std.atomic.Value(u32) = .init(0),

    pub const http_routes = routes.routes(.{
        .methods = .{
            .ok = routes.get("/ok", .{}),
            .fail = routes.get("/fail", .{}),
            .gated = routes.get("/gated", .{}),
            // A second of work past a deadline of 50 ms, and of 5 ms.
            .slow = routes.get("/slow", .{ .timeout = std.Io.Duration.fromMilliseconds(50) }),
            .short = routes.get("/short", .{ .timeout = std.Io.Duration.fromMilliseconds(5) }),
            // Five seconds of work within the server's deadline.
            .stay = routes.get("/stay", .{}),
            // 5 ms ± 1 ms of work, a deadline of 5 ms.
            .edge = routes.get("/edge", .{ .timeout = std.Io.Duration.fromMilliseconds(5) }),
        },
    });

    pub fn ok(_: *WaitController, _: *Context) !void {}
    pub fn fail(_: *WaitController, _: *Context) !void {
        return error.TodoNotFound;
    }
    pub fn gated(self: *WaitController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try self.gate.wait(ctx.io());
    }
    pub fn slow(self: *WaitController, ctx: *Context) !void {
        return self.work(ctx, .fromSeconds(1));
    }
    pub fn short(self: *WaitController, ctx: *Context) !void {
        return self.work(ctx, .fromSeconds(1));
    }
    pub fn stay(self: *WaitController, ctx: *Context) !void {
        return self.work(ctx, .fromSeconds(5));
    }
    pub fn edge(self: *WaitController, ctx: *Context) !void {
        // From 4 to 6 ms, spread over the calls.
        const n: u64 = self.edges.fetchAdd(1, .monotonic);
        const spread: i64 = @intCast((n *% 2654435761) % 2001);
        try ctx.io().sleep(.fromMicroseconds(4000 + spread), .awake);
        try ctx.response.text("done");
    }

    /// Works for `duration`; when an error ends the work, records it and
    /// what the operation says then.
    fn work(self: *WaitController, ctx: *Context, duration: std.Io.Duration) !void {
        ctx.io().sleep(duration, .awake) catch |err| {
            _ = self.canceled.fetchAdd(1, .monotonic);
            ctx.operation().check(ctx.now()) catch |reason| switch (reason) {
                error.DeadlineExceeded => _ = self.deadline_exceeded.fetchAdd(1, .monotonic),
                error.Cancelled => _ = self.cancelled.fetchAdd(1, .monotonic),
            };
            return err;
        };
    }
};

fn sinceMs(io: std.Io, start: std.Io.Timestamp) i64 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

fn expectProblemCode(res: *TestingBackend.Response, code: []const u8) !void {
    try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    const problem = try std.json.parseFromSliceLeaky(struct { code: []const u8 }, res.arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings(code, problem.code);
}

/// Waits until `count` reaches `n`, two seconds at most.
fn waitCount(io: std.Io, count: *const std.atomic.Value(u32), n: u32) !void {
    var tries: u32 = 0;
    while (count.load(.monotonic) < n) : (tries += 1) {
        if (tries == 2000) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A request on a task of its own; its response, or null for an error.
fn requestInto(backend: *TestingBackend, io: std.Io, req: TestingBackend.Request, out: *?TestingBackend.Response) std.Io.Cancelable!void {
    out.* = backend.request(io, req) catch null;
}

/// How many more tasks `scarce_vtable` gives before `Group.concurrent` and
/// `Select.concurrent` fail with `ConcurrencyUnavailable`.
var tasks_left: std.atomic.Value(u32) = .init(0);

fn concurrentWhileLeft(
    userdata: ?*anyopaque,
    group: *std.Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) std.Io.ConcurrentError!void {
    var left = tasks_left.load(.monotonic);
    while (left > 0) {
        left = tasks_left.cmpxchgWeak(left, left - 1, .monotonic, .monotonic) orelse
            return testing.io.vtable.groupConcurrent(userdata, group, context, context_alignment, start);
    }
    return error.ConcurrencyUnavailable;
}

test "when the runtime gives no task, the request gets 503" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "when the runtime gives no task, the request gets 503");
    defer dog.stop(io);
    var scarce_vtable = io.vtable.*;
    scarce_vtable.groupConcurrent = concurrentWhileLeft;
    const scarce: std.Io = .{ .userdata = io.userdata, .vtable = &scarce_vtable };
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits} });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // the 503 is logged as a warning
    defer testing.log_level = level;

    // No task at all: the backend serves on the caller's task, and the
    // guard gets none.
    tasks_left.store(0, .monotonic);
    var none = try b.request(scarce, .{ .method = .GET, .target = "/gated" });
    defer none.deinit();
    try testing.expectEqual(503, none.status);
    try expectProblemCode(&none, "unavailable");
    // A task for the backend and one for the guard, none for the request:
    // the guard is canceled.
    tasks_left.store(2, .monotonic);
    var no_request = try b.request(scarce, .{ .method = .GET, .target = "/gated" });
    defer no_request.deinit();
    try testing.expectEqual(503, no_request.status);
    try testing.expectEqual(0, tasks_left.load(.monotonic));
    // No handler began, and no place is held.
    try testing.expectEqual(0, waits.entered.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));

    var served = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer served.deinit();
    try testing.expectEqual(204, served.status);
}

test "a handler past its deadline gets 504, and its I/O returns Canceled" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "a handler past its deadline gets 504, and its I/O returns Canceled");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits} });
    defer server.deinit(io);
    try server.start(io);

    const start = std.Io.Clock.awake.now(io);
    var res = try b.request(io, .{ .method = .GET, .target = "/slow" });
    defer res.deinit();
    const elapsed = sinceMs(io, start);
    try testing.expectEqual(504, res.status);
    try expectProblemCode(&res, "timeout");
    try testing.expect(!res.aborted);
    // At the route's deadline of 50 ms, long before its second of work.
    try testing.expect(elapsed >= 50 and elapsed < 500);
    try testing.expectEqual(1, waits.canceled.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));
}

test "a client that leaves cancels the request: no response, the handler sees Canceled" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "a client that leaves cancels the request: no response, the handler sees Canceled");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits} });
    defer server.deinit(io);
    try server.start(io);

    const start = std.Io.Clock.awake.now(io);
    var res = try b.request(io, .{ .method = .GET, .target = "/stay", .leave_after = .fromMilliseconds(20) });
    defer res.deinit();
    try testing.expect(sinceMs(io, start) < 1000);
    try testing.expect(res.aborted);
    try testing.expectEqual(0, res.status);
    try testing.expectEqual(1, waits.canceled.load(.monotonic));
    // The client left: the request's token is canceled too.
    try testing.expectEqual(1, waits.cancelled.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));

    // A client that leaves after its response changes nothing.
    var quick = try b.request(io, .{ .method = .GET, .target = "/ok", .leave_after = .fromMilliseconds(500) });
    defer quick.deinit();
    try testing.expectEqual(204, quick.status);
}

test "after a deadline the operation reports DeadlineExceeded, never Cancelled" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "after a deadline the operation reports DeadlineExceeded, never Cancelled");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits} });
    defer server.deinit(io);
    try server.start(io);

    var res = try b.request(io, .{ .method = .GET, .target = "/slow" });
    defer res.deinit();
    try testing.expectEqual(504, res.status);
    try testing.expectEqual(1, waits.canceled.load(.monotonic));
    try testing.expectEqual(1, waits.deadline_exceeded.load(.monotonic));
    try testing.expectEqual(0, waits.cancelled.load(.monotonic));
}

test "the request over max_in_flight gets 503" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "the request over max_in_flight gets 503");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits}, .max_in_flight = 2 });
    defer server.deinit(io);
    try server.start(io);

    var held: [2]?TestingBackend.Response = .{ null, null };
    var clients: std.Io.Group = .init;
    defer clients.cancel(io);
    defer for (&held) |*r| if (r.*) |*res| res.deinit();
    for (&held) |*out| try clients.concurrent(io, requestInto, .{ &b, io, .{ .method = .GET, .target = "/gated" }, out });
    try waitCount(io, &waits.entered, 2);
    try testing.expectEqual(2, inFlight(&server));

    var over = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer over.deinit();
    try testing.expectEqual(503, over.status);
    try expectProblemCode(&over, "unavailable");
    try testing.expectEqual(2, inFlight(&server));

    waits.gate.set(io);
    try clients.await(io);
    for (held) |r| try testing.expectEqual(204, r.?.status);
    try testing.expectEqual(0, inFlight(&server));
    var after = try b.request(io, .{ .method = .GET, .target = "/ok" });
    defer after.deinit();
    try testing.expectEqual(204, after.status);
}

/// The outcomes of review focus 2: a request of each, and the status it
/// gets when it has a place (0: aborted, no response).
const Outcome = struct { method: std.http.Method, target: []const u8, leave_after: ?std.Io.Duration = null, status: u16 };

const outcomes = [_]Outcome{
    .{ .method = .GET, .target = "/ok", .status = 204 },
    .{ .method = .GET, .target = "/fail", .status = 500 },
    .{ .method = .GET, .target = "/short", .status = 504 },
    .{ .method = .GET, .target = "/stay", .leave_after = .fromMilliseconds(1), .status = 0 },
    .{ .method = .GET, .target = "/nothing", .status = 404 },
    .{ .method = .PUT, .target = "/ok", .status = 405 },
};

/// One request of `outcome`; a status other than its own or 503 counts in
/// `wrong`.
fn requestOutcome(backend: *TestingBackend, io: std.Io, outcome: Outcome, wrong: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    var res = backend.request(io, .{ .method = outcome.method, .target = outcome.target, .leave_after = outcome.leave_after }) catch {
        _ = wrong.fetchAdd(1, .monotonic);
        return;
    };
    defer res.deinit();
    const refused = !res.aborted and res.status == 503;
    const ok = refused or if (outcome.status == 0) res.aborted else !res.aborted and res.status == outcome.status;
    if (!ok) {
        std.debug.print("{t} {s}: {d}, aborted {}\n", .{ outcome.method, outcome.target, res.status, res.aborted });
        _ = wrong.fetchAdd(1, .monotonic);
    }
}

test "in-flight slots come back after every outcome" {
    // Review focus 2: 1 002 requests, six at a time, one of each outcome,
    // on four places, so that some get 503.
    const io = testing.io;
    var dog = try Watchdog.start(io, "in-flight slots come back after every outcome");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits}, .max_in_flight = 4 });
    defer server.deinit(io);
    try server.start(io);
    const level = testing.log_level;
    testing.log_level = .err; // each 500 is logged as a warning
    defer testing.log_level = level;

    var wrong: std.atomic.Value(u32) = .init(0);
    for (0..167) |_| {
        var clients: std.Io.Group = .init;
        defer clients.cancel(io);
        for (outcomes) |outcome| try clients.concurrent(io, requestOutcome, .{ &b, io, outcome, &wrong });
        try clients.await(io);
    }
    try testing.expectEqual(0, wrong.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));

    // All four places are free: four requests at once all enter.
    var held: [4]?TestingBackend.Response = .{ null, null, null, null };
    var clients: std.Io.Group = .init;
    defer clients.cancel(io);
    defer for (&held) |*r| if (r.*) |*res| res.deinit();
    for (&held) |*out| try clients.concurrent(io, requestInto, .{ &b, io, .{ .method = .GET, .target = "/gated" }, out });
    try waitCount(io, &waits.entered, 4);
    waits.gate.set(io);
    try clients.await(io);
    for (held) |r| try testing.expectEqual(204, r.?.status);
    try testing.expectEqual(0, inFlight(&server));
}

/// Requests of `edge` until `taken` reaches `total`: each must be 200 with
/// its body or 504, never aborted; the others count in `wrong`.
fn requestEdges(backend: *TestingBackend, io: std.Io, taken: *std.atomic.Value(u32), total: u32, counts: *[2]std.atomic.Value(u32), wrong: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    while (taken.fetchAdd(1, .monotonic) < total) {
        var res = backend.request(io, .{ .method = .GET, .target = "/edge" }) catch {
            _ = wrong.fetchAdd(1, .monotonic);
            continue;
        };
        defer res.deinit();
        if (!res.aborted and res.status == 200 and std.mem.eql(u8, res.body, "done")) {
            _ = counts[0].fetchAdd(1, .monotonic);
        } else if (!res.aborted and res.status == 504 and std.mem.eql(u8, res.header("content-type") orelse "", "application/problem+json")) {
            _ = counts[1].fetchAdd(1, .monotonic);
        } else {
            std.debug.print("/edge: {d}, aborted {}, body {s}\n", .{ res.status, res.aborted, res.body });
            _ = wrong.fetchAdd(1, .monotonic);
        }
    }
}

test "a handler that ends at its deadline gets exactly one outcome" {
    // Review focus 3: 1 000 requests, 16 at a time; the handler ends 5 ms
    // ± 1 ms in, the deadline is 5 ms. Each gets the handler's response or
    // 504, written once (the backend checks each write).
    const io = testing.io;
    var dog = try Watchdog.start(io, "a handler that ends at its deadline gets exactly one outcome");
    defer dog.stop(io);
    var waits: WaitController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&waits} });
    defer server.deinit(io);
    try server.start(io);

    var taken: std.atomic.Value(u32) = .init(0);
    var counts: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) };
    var wrong: std.atomic.Value(u32) = .init(0);
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    for (0..16) |_| try workers.concurrent(io, requestEdges, .{ &b, io, &taken, 1000, &counts, &wrong });
    try workers.await(io);
    try testing.expectEqual(0, wrong.load(.monotonic));
    try testing.expectEqual(1000, counts[0].load(.monotonic) + counts[1].load(.monotonic));
    try testing.expectEqual(1000, waits.edges.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));
}

/// Handlers for the stop: `quick` ends once the test opens its gate,
/// `stuck` works ten seconds, `deaf` ignores its cancelation for two, and
/// `stop` stops the server itself.
const StopController = struct {
    server: ?*Server = null,
    entered: std.atomic.Value(u32) = .init(0),
    gate: std.Io.Event = .unset,
    /// `stuck` handlers that an error ended, and those whose token was
    /// canceled then.
    canceled: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),

    pub const http_routes = routes.routes(.{ .methods = .{
        .quick = routes.get("/quick", .{}),
        .stuck = routes.get("/stuck", .{}),
        .deaf = routes.get("/deaf", .{}),
        .stop = routes.post("/stop", .{}),
    } });

    pub fn quick(self: *StopController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        try self.gate.wait(ctx.io());
        try ctx.response.text("done");
    }
    pub fn stuck(self: *StopController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        ctx.io().sleep(.fromSeconds(10), .awake) catch |err| {
            _ = self.canceled.fetchAdd(1, .monotonic);
            if (ctx.operation().isCancelled()) _ = self.cancelled.fetchAdd(1, .monotonic);
            return err;
        };
    }
    pub fn deaf(self: *StopController, ctx: *Context) !void {
        _ = self.entered.fetchAdd(1, .monotonic);
        const io = ctx.io();
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        io.sleep(.fromSeconds(2), .awake) catch {};
    }
    pub fn stop(self: *StopController, ctx: *Context) !void {
        self.server.?.requestStop(ctx.io());
        try ctx.response.text("stopping");
    }
};

test "requestStop: requests finish within shutdown_grace, the rest are canceled, and in-flight is 0 after" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "requestStop: requests finish within shutdown_grace");
    defer dog.stop(io);
    var stops: StopController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&stops}, .shutdown_grace = std.Io.Duration.fromMilliseconds(300) });
    defer server.deinit(io);
    try server.start(io);

    var results: [4]?TestingBackend.Response = @splat(null);
    var clients: std.Io.Group = .init;
    defer clients.cancel(io);
    defer for (&results) |*r| if (r.*) |*res| res.deinit();
    for (&results, [_][]const u8{ "/quick", "/stuck", "/quick", "/stuck" }) |*out, target|
        try clients.concurrent(io, requestInto, .{ &b, io, .{ .method = .GET, .target = target }, out });
    try waitCount(io, &stops.entered, 4);

    const start = std.Io.Clock.awake.now(io);
    server.requestStop(io);
    // The quick ones end within the grace, with their responses.
    stops.gate.set(io);
    try server.shutdown(io);
    // The stuck ones are canceled when the grace is over.
    const elapsed = sinceMs(io, start);
    try testing.expect(elapsed >= 300 and elapsed < 1300);
    try clients.await(io);
    for (results, 0..) |r, i| {
        const res = r.?;
        if (i % 2 == 0) {
            try testing.expectEqual(200, res.status);
            try testing.expectEqualStrings("done", res.body);
            try testing.expect(!res.aborted);
        } else {
            try testing.expect(res.aborted);
            try testing.expectEqual(0, res.status);
        }
    }
    // Their I/O returned Canceled, and their tokens are canceled.
    try testing.expectEqual(2, stops.canceled.load(.monotonic));
    try testing.expectEqual(2, stops.cancelled.load(.monotonic));
    try testing.expectEqual(0, inFlight(&server));
    try testing.expectEqual(Server.State.stopped, server.state());
}

test "requestStop from a handler: its response goes out, then the server stops" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "requestStop from a handler");
    defer dog.stop(io);
    var stops: StopController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&stops} });
    defer server.deinit(io);
    try server.start(io);
    stops.server = &server;

    var res = try b.request(io, .{ .method = .POST, .target = "/stop" });
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("stopping", res.body);
    try testing.expect(!res.aborted);
    try server.wait(io);
    try testing.expectEqual(Server.State.stopped, server.state());
    try testing.expectError(error.NotStarted, b.request(io, .{ .method = .POST, .target = "/stop" }));
}

test "shutdown gives up on a request that ignores its cancelation; the stop ends with it" {
    const io = testing.io;
    var dog = try Watchdog.start(io, "shutdown gives up on a request that ignores its cancelation");
    defer dog.stop(io);
    var stops: StopController = .{};
    var b: TestingBackend = .init(testing.allocator);
    defer b.deinit();
    var server = try Server.init(testing.allocator, .{ .backend = b.backend(), .controllers = .{&stops}, .shutdown_grace = std.Io.Duration.fromMilliseconds(50) });
    defer server.deinit(io);
    try server.start(io);

    var result: ?TestingBackend.Response = null;
    var client = try io.concurrent(requestInto, .{ &b, io, .{ .method = .GET, .target = "/deaf" }, &result });
    defer client.cancel(io) catch {};
    defer if (result) |*res| res.deinit();
    try waitCount(io, &stops.entered, 1);

    // The grace, then a second for the canceled request: it works on.
    const start = std.Io.Clock.awake.now(io);
    try testing.expectError(error.ShutdownTimeout, server.shutdown(io));
    try testing.expect(sinceMs(io, start) >= 1000);
    try testing.expectEqual(Server.State.draining, server.state());
    // The stop ends when the request does, without a response.
    try server.wait(io);
    try testing.expectEqual(Server.State.stopped, server.state());
    try client.await(io);
    try testing.expect(result.?.aborted);
    try testing.expectEqual(0, inFlight(&server));
}
