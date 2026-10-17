//! One request through the server (design sections 5, 8, 11 and 17), on
//! the task the backend runs it on: the context with the request's trace
//! and id, the route, the handler, and the response. A handler that wrote
//! nothing answers 204, an `http.Json(T)` its value, an error
//! `application/problem+json` with the status of `http.defaultStatus`;
//! a request canceled (the client has gone, the server stops) gets none.
const std = @import("std");
const core = @import("core");
const Backend = @import("Backend.zig");
const Exchange = Backend.Exchange;
const Server = @import("Server.zig");
const Context = @import("Context.zig");
const errors = @import("errors.zig");
const ids = @import("ids.zig");
const path = @import("path.zig");
const Allow = @import("router.zig").Allow;
const h1 = @import("h1/head.zig");

const log = std.log.scoped(.http);

/// The server as the handler of its backend.
pub fn handler(server: *Server) Backend.Handler {
    return .{ .ptr = server, .serve = serveErased };
}

fn serveErased(ptr: *anyopaque, io: std.Io, exchange: *Exchange) void {
    serve(@ptrCast(@alignCast(ptr)), io, exchange);
}

/// Serves `exchange` to its end: the response sent, or aborted.
pub fn serve(server: *Server, io: std.Io, exchange: *Exchange) void {
    const arena = exchange.arena;
    // Out of memory for the tracestate: a trace of its own.
    const trace = ids.traceOf(io, arena, exchange.fields) catch ids.newTrace(io);
    const target = path.splitTarget(exchange.target);
    var ctx: Context = .{
        .request = .{
            .method = exchange.method,
            .path = target.path,
            .internal = .{ .exchange = exchange, .io = io, .query = target.query },
        },
        .response = .{ .internal = .{ .arena = arena } },
        .internal = .{
            .io = io,
            .operation = core.Context.root.withTrace(trace),
            .arena = arena,
            .request_id = ids.newRequestId(io),
            .trace_id = trace.trace_id.toHex(),
        },
    };
    if (run(server, &ctx)) {
        const code = ctx.response.internal.code orelse 200;
        if (code < 200 or code > 599) {
            log.warn("{s} set the status {d}, which is not a final status; the response is 500 (request {s})", .{ routeName(&ctx), code, ctx.requestId() });
            setProblem(&ctx, errors.DefaultErrors.problem(error.Unexpected));
        }
    } else |err| {
        if (errors.isCancellation(err)) {
            exchange.abort(io);
            return;
        }
        if (errors.defaultStatus(err) == 500)
            log.warn("{s} failed with error.{t}; the response is 500 (request {s})", .{ routeName(&ctx), err, ctx.requestId() });
        setProblem(&ctx, errors.DefaultErrors.problem(err));
    }
    send(&ctx, exchange);
}

/// The route and its handler, or the error that answers the request.
fn run(server: *Server, ctx: *Context) anyerror!void {
    const arena = ctx.internal.arena;
    const method = ctx.request.method;
    if (std.mem.eql(u8, ctx.request.path, "*")) {
        // `OPTIONS *` asks about the server, not a path.
        if (method != .OPTIONS) return error.InvalidRequest;
        return answerOptions(ctx, server.router.serverAllow());
    }
    const normalized = try path.normalize(arena, ctx.request.path);
    const values = try arena.alloc([]const u8, server.router.max_params);
    switch (server.router.match(method, normalized, values)) {
        .found => |found| {
            const route = &server.routes[found.route];
            ctx.internal.route = route.info;
            ctx.internal.params = found.params;
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

/// OPTIONS without a route of its own: 204 with `Allow`.
fn answerOptions(ctx: *Context, allow: Allow) error{ InvalidHeaderValue, OutOfMemory }!void {
    try ctx.response.setHeader("allow", allow.header());
    _ = ctx.response.status(204);
}

/// Replaces the response with `problem` as problem+json. The fields of
/// the content go with the old body; the others stay (`Allow`, those of
/// the application).
fn setProblem(ctx: *Context, problem: errors.Problem) void {
    const res = &ctx.response.internal;
    var kept: usize = 0;
    for (res.headers.items) |f| {
        if (isContentField(f.name)) continue;
        res.headers.items[kept] = f;
        kept += 1;
    }
    res.headers.shrinkRetainingCapacity(kept);
    res.code = problem.status;
    res.content_type = "application/problem+json";
    res.body = std.json.Stringify.valueAlloc(res.arena, problem, .{ .emit_null_optional_fields = false }) catch internal: {
        // Out of memory: the problem of every 500, known at compile time.
        res.code = 500;
        break :internal internal_problem;
    };
}

const internal_problem = "{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500,\"code\":\"internal\",\"errors\":[]}";

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
    pub fn fail(_: *TodosV1Controller, ctx: *Context) error{ TodoNotFound, InvalidHeaderValue, OutOfMemory }!void {
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
    try testing.expect(op.deadline == null and op.cancellation == null);
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
