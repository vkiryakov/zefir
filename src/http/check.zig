//! The Debug check of a route's declarations: on a route
//! of a controller with `pub const openapi`, the server compares what the
//! handler, the middleware and the error handler do with what the route
//! declares, and answers a mismatch with its own 500 and a line in the log:
//!
//! ```text
//! zefir.http: GET /api/v1/todos (TodosV1Controller.list) reads the query as ListQuery, but declares .query = ListTodosQuery
//! zefir.http: POST /api/v1/todos (TodosV1Controller.create) answered 202, which it does not declare in .responses
//! ```
//!
//! At compile time `tableOf` builds what a route declares: the DTO of each
//! source of its input, the responses it answers with (its `.responses`,
//! else its default response: 200 `application/json` for `http.Json(T)`,
//! 204 for `!void`, 200 `text/event-stream` for SSE), the errors it can
//! give the error handler, whose answers `mapError` gives, and the events
//! of an SSE route; and what the middleware of its chain declare in their
//! own `pub const openapi`: the `.query`, `.headers` and `.cookies` they
//! read, and the `.responses` they write themselves.
//!
//! At run time it compares:
//! - each input call (`ctx.path`, `query`, `headers`, `cookies`, `json`,
//!   `form`, and so `ctx.input`): its type must be one the route or a
//!   middleware of its chain declares for that source;
//! - each response of the route, from the handler, from a middleware that
//!   answers `.handled`, from the error handler: its status and the media
//!   type of its body must be among the responses of the route and of its
//!   middleware, or among the answers `mapError` gives its errors, in the
//!   error handler's media type;
//! - `subscribe` of an `http.sse.Manager(Events)`: `Events` must be the
//!   route's `.events`.
//!
//! A call works as usual, and no error set changes: a mismatch is kept,
//! and right before the head of the response goes out, the response becomes
//! the server's 500 problem+json, with one line in the log. The answers the
//! server writes itself go as they are: the answer to an error that is not
//! one of the route's (the 504 of a deadline, the 503 of a task the runtime
//! did not give), the 408 or 400 of a body that did not arrive whole, the
//! server's own 500; the automatic OPTIONS, a 405 and a 404 belong to no
//! route. Only routes of controllers with `openapi` are checked, and only in
//! Debug builds: elsewhere none of this is compiled.
//!
//! zefir-http does not import zefir-openapi: it reads the `openapi` of a
//! middleware by the names of its fields. `.query`, `.headers` and
//! `.cookies` are types, `void` for none; `.responses` holds a field per
//! status, named as in `std.http.Status`, optional or not, whose
//! `.content_type` or `.json` give its body, and neither none. A
//! `zefir.openapi.MiddlewareDoc` has this form, and so does a literal:
//! `pub const openapi = .{ .query = PageQuery, .responses = .{ .not_modified = .{} } };`.
const std = @import("std");
const builtin = @import("builtin");
const routes = @import("routes.zig");
const plan = @import("plan.zig");
const mw = @import("middleware.zig");
const errors = @import("errors.zig");
const describe = @import("describe.zig");
const flow = @import("flow.zig");
const Context = @import("Context.zig");

const log = std.log.scoped(.http);

/// The check runs in Debug builds only.
pub const enabled = builtin.mode == .debug;

/// Where an input call reads from: `ctx.path`, `query`, `headers`,
/// `cookies`, `json` (the body) and `form`. The names are those of the
/// options of a route.
pub const Source = enum { path, query, headers, cookies, body, form };

/// A type at run time: who it is, and its name for the log.
const TypeRef = struct { id: *const anyopaque, name: []const u8 };

/// A response a route may answer with: its status and the media type of
/// its body, null for none.
const Answer = struct { status: u16, media: ?[]const u8 };

/// A DTO that a middleware of the chain declares for a source of input.
const Declared = struct { source: Source, dto: TypeRef, by: []const u8 };

/// What a route of a controller with `openapi` declares, as the check
/// compares its requests with it.
pub const Table = struct {
    /// The DTO the route declares for each source, by `Source`.
    own: [@typeInfo(Source).@"enum".field_names.len]?TypeRef,
    /// The query, headers and cookies that the middleware of its chain
    /// declare.
    chain: []const Declared,
    /// The responses of the route, as `.responses` lists them or its
    /// default response, then those its middleware declare.
    responses: []const Answer,
    /// The errors the route can give the error handler; null when one of
    /// its places returns `anyerror`, so that every error may be its.
    errors: ?[]const anyerror,
    /// The status `mapError` gives an error.
    statusOf: *const fn (err: anyerror) u16,
    /// The media type of the bodies of `mapError`: `application/problem+json`
    /// for `http.Problem`, else `application/json`.
    error_media: []const u8,
    /// The events of an SSE route; null on another.
    events: ?TypeRef,
};

/// What a route keeps of the check: its table, or null when its controller
/// has no `openapi`; nothing outside Debug.
pub const TableRef = if (enabled) ?*const Table else void;

/// The table of the route `handler` of the controller `C`, made as `R`,
/// whose chain is `chain` (the server's elements, then the route's own) and
/// whose error handler is `H`. It raises its eval branch quota by its work:
/// the application sets none.
pub fn tableOf(comptime C: type, comptime handler: []const u8, comptime R: type, comptime chain: []const mw.Elem, comptime H: type) TableRef {
    if (!enabled) return {};
    if (!@hasDecl(C, "openapi")) return null;
    comptime {
        @setEvalBranchQuota(20_000 + 2_000 * chain.len);
        const Errors = describe.RouteErrors(C, handler, chain);
        const names = @typeInfo(Errors).error_set.error_names;
        if (names) |list| @setEvalBranchQuota(20_000 + 2_000 * chain.len + 200 * list.len);
        const table: Table = .{
            .own = .{
                dtoOf(R.Path),
                dtoOf(R.Query),
                dtoOf(R.Headers),
                dtoOf(R.Cookies),
                dtoOf(R.Body),
                dtoOf(R.Form),
            },
            .chain = chainInputs(chain),
            .responses = answersOf(R, ValueOf(C, handler)) ++ chainAnswers(chain),
            .errors = if (names) |list| errorsOf(list) else null,
            .statusOf = &StatusOf(H).status,
            .error_media = if (ErrorBodyOf(H) == errors.Problem) "application/problem+json" else "application/json",
            .events = dtoOf(R.Events),
        };
        const final = table;
        return &final;
    }
}

/// The type of `T` at run time, null for void.
fn dtoOf(comptime T: type) ?TypeRef {
    if (T == void) return null;
    return .{ .id = idOf(T), .name = plan.typeName(T) };
}

/// Who `T` is at run time: the address of a byte of its own.
fn idOf(comptime T: type) *const anyopaque {
    return @ptrCast(&Id(T).byte);
}

fn Id(comptime T: type) type {
    return struct {
        comptime {
            _ = T;
        }
        var byte: u8 = 0;
    };
}

/// The `T` of the `http.Json(T)` the handler returns; void for `!void` and
/// for SSE.
fn ValueOf(comptime C: type, comptime handler: []const u8) type {
    const R = @typeInfo(@TypeOf(@field(C, handler))).@"fn".return_type.?;
    const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
    return if (Payload == void) void else Payload.Value;
}

/// The responses of the route `R`, whose handler answers with `Value`.
fn answersOf(comptime R: type, comptime Value: type) []const Answer {
    if (R.route_kind == .sse) return &.{.{ .status = 200, .media = "text/event-stream" }};
    if (R.responses.len == 0) return &.{if (Value != void) .{ .status = 200, .media = "application/json" } else .{ .status = 204, .media = null }};
    var out: [R.responses.len]Answer = undefined;
    for (R.responses, &out) |r, *answer| {
        const status = @backingInt(r.status);
        const media: ?[]const u8 = if (r.content_type) |text|
            mediaType(text)
        else if (r.json != void or (Value != void and status >= 200 and status <= 299))
            "application/json"
        else
            null;
        answer.* = .{ .status = status, .media = media };
    }
    const final = out;
    return &final;
}

/// The query, headers and cookies that the elements of `chain` declare in
/// their `openapi`.
fn chainInputs(comptime chain: []const mw.Elem) []const Declared {
    var out: []const Declared = &.{};
    for (chain) |e| {
        if (@hasDecl(e.Impl, "openapi")) out = out ++ inputsOf(e.Impl, e.name);
    }
    return out;
}

/// The responses that the elements of `chain` declare in their `openapi`.
fn chainAnswers(comptime chain: []const mw.Elem) []const Answer {
    var out: []const Answer = &.{};
    for (chain) |e| {
        if (@hasDecl(e.Impl, "openapi")) out = out ++ middlewareAnswers(e.Impl, e.name);
    }
    return out;
}

/// The `openapi` of the middleware `Impl`, which messages call `name`.
fn docOf(comptime Impl: type, comptime name: []const u8) @TypeOf(Impl.openapi) {
    const doc = Impl.openapi;
    if (@typeInfo(@TypeOf(doc)) != .@"struct")
        @compileError("zefir.http: the openapi of the middleware " ++ name ++ " is a zefir.openapi.MiddlewareDoc, such as .{ .query = PageQuery }; got " ++ plan.typeName(@TypeOf(doc)));
    return doc;
}

/// The `.query`, `.headers` and `.cookies` of the `openapi` of `Impl`.
fn inputsOf(comptime Impl: type, comptime name: []const u8) []const Declared {
    const doc = docOf(Impl, name);
    var out: []const Declared = &.{};
    for ([_]Source{ .query, .headers, .cookies }) |source| {
        if (!@hasField(@TypeOf(doc), @tagName(source))) continue;
        const T = @field(doc, @tagName(source));
        if (@TypeOf(T) != type)
            @compileError("zefir.http: the openapi of the middleware " ++ name ++ ": ." ++ @tagName(source) ++ " is the type of a DTO, such as ." ++ @tagName(source) ++ " = PageQuery, or void");
        if (T != void) out = out ++ [_]Declared{.{ .source = source, .dto = dtoOf(T).?, .by = name }};
    }
    return out;
}

/// The `.responses` of the `openapi` of `Impl`: a field per status, named
/// as in `std.http.Status`; an optional one that is null declares nothing.
fn middlewareAnswers(comptime Impl: type, comptime name: []const u8) []const Answer {
    const doc = docOf(Impl, name);
    if (!@hasField(@TypeOf(doc), "responses")) return &.{};
    const list = doc.responses;
    const L = @TypeOf(list);
    const form = "zefir.http: the openapi of the middleware " ++ name ++ ": .responses ";
    if (@typeInfo(L) != .@"struct") @compileError(form ++ "is a struct of statuses, such as .responses = .{ .not_modified = .{} }");
    var out: []const Answer = &.{};
    for (@typeInfo(L).@"struct".field_names) |key| {
        if (!@hasField(std.http.Status, key)) @compileError(form ++ "names ." ++ key ++ "; its keys are names of std.http.Status, such as .not_modified");
        const value = @field(list, key);
        const entry = if (@typeInfo(@TypeOf(value)) == .optional) value orelse continue else value;
        const E = @TypeOf(entry);
        const content_type: ?[]const u8 = if (@hasField(E, "content_type")) entry.content_type else null;
        const json: type = if (@hasField(E, "json")) entry.json else void;
        const media: ?[]const u8 = if (content_type) |text| mediaType(text) else if (json != void) "application/json" else null;
        out = out ++ [_]Answer{.{ .status = @backingInt(@field(std.http.Status, key)), .media = media }};
    }
    return out;
}

/// The errors of `names` as values.
fn errorsOf(comptime names: []const [:0]const u8) []const anyerror {
    var out: [names.len]anyerror = undefined;
    for (names, &out) |name, *err| err.* = @field(anyerror, name);
    const final = out;
    return &final;
}

fn ErrorBodyOf(comptime H: type) type {
    return @typeInfo(@TypeOf(H.mapError)).@"fn".return_type.?.Body;
}

/// The status that `H.mapError` gives an error, as a function of run time:
/// `mapError` is pure.
fn StatusOf(comptime H: type) type {
    return struct {
        fn status(err: anyerror) u16 {
            return H.mapError(err).status;
        }
    };
}

/// A media type without its parameters: "text/csv; charset=utf-8" is
/// "text/csv".
pub fn mediaType(content_type: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], " \t");
}

// ---------- At run time ----------

/// What the check keeps of a request, in its context; nothing outside
/// Debug.
pub const State = if (enabled) struct {
    /// The route the request matched, when the check compares it.
    route: ?Checked = null,
    /// The first input call or `subscribe` that does not match the route.
    mismatch: ?Mismatch = null,
    /// The response that goes out is one the server writes itself: it goes
    /// as it is.
    untouched: bool = false,
} else struct {};

/// A route the check compares: its table, and its names for the line.
const Checked = struct { info: *const routes.RouteInfo, table: *const Table };

const Mismatch = union(enum) {
    /// An input call read `source` as a type of the name `read`.
    input: struct { source: Source, read: []const u8 },
    /// `subscribe` of a manager of events of the type of this name.
    events: []const u8,
};

/// The request of `ctx` matched the route `info`, whose table is `table`:
/// from here on the check compares it, if the route has a table. Before
/// the server's middleware runs, so that its input calls count too.
pub fn begin(ctx: *Context, info: *const routes.RouteInfo, table: TableRef) void {
    if (!enabled) return;
    // Not in the literal: its result location, the optional, would be set
    // before the return.
    const t = table orelse return;
    ctx.internal.check.route = .{ .info = info, .table = t };
}

/// An input call of `ctx` reads `source` as a `T`.
pub fn input(ctx: *Context, comptime source: Source, comptime T: type) void {
    if (!enabled) return;
    const route = ctx.internal.check.route orelse return;
    if (allowsInput(route.table, source, idOf(T))) return;
    record(ctx, route, .{ .input = .{ .source = source, .read = comptime plan.typeName(T) } });
}

/// `subscribe` of an `http.sse.Manager(Events)` on the route of `ctx`.
pub fn subscribe(ctx: *Context, comptime Events: type) void {
    if (!enabled) return;
    const route = ctx.internal.check.route orelse return;
    if (route.table.events) |declared| if (declared.id == idOf(Events)) return;
    record(ctx, route, .{ .events = comptime plan.typeName(Events) });
}

/// The error handler answers `err`. An error that is not one of the
/// route's comes from the server, such as the 504 of a deadline: its
/// answer goes as it is.
pub fn answering(ctx: *Context, err: anyerror) void {
    if (!enabled) return;
    const route = ctx.internal.check.route orelse return;
    // A place of the route returns anyerror: every error may be its.
    const list = route.table.errors orelse return;
    for (list) |e| {
        if (e == err) return;
    }
    ctx.internal.check.untouched = true;
}

/// The response that goes out is one the server writes itself: the 408 or
/// 400 of a body that did not arrive whole, the server's own 500.
pub fn leave(ctx: *Context) void {
    if (!enabled) return;
    ctx.internal.check.untouched = true;
}

/// Right before the head of the response goes out, after the `onResponse`
/// phases: true when the response goes as it is; false when the check put
/// the server's 500 problem+json in its place and logged why, for a
/// mismatch kept before, or for a status or a media type that the route
/// does not declare.
pub fn head(ctx: *Context) bool {
    if (!enabled) return true;
    const state = &ctx.internal.check;
    const route = state.route orelse return true;
    if (state.mismatch) |m| {
        report(ctx, route, .{ .mismatch = m });
        // The server's own answer goes as it is, with the line of the
        // mismatch all the same.
        if (state.untouched) return true;
    } else {
        if (state.untouched) return true;
        const res = &ctx.response.internal;
        const status = res.statusCode();
        const media: ?[]const u8 = if (res.body == .none) null else if (res.content_type) |text| mediaType(text) else null;
        if (allowsAnswer(route.table, status, media)) return true;
        report(ctx, route, .{ .answer = .{ .status = status, .media = media } });
    }
    flow.replaceWithInternal(&ctx.response.internal);
    return false;
}

/// Keeps the first mismatch of the request for the head of its response.
/// Once the head has gone, as in the `.on_close` of a stream, the mismatch
/// can change nothing: its line goes to the log at once.
fn record(ctx: *Context, route: Checked, m: Mismatch) void {
    if (ctx.response.internal.state != .uncommitted) return report(ctx, route, .{ .mismatch = m });
    if (ctx.internal.check.mismatch == null) ctx.internal.check.mismatch = m;
}

fn allowsInput(t: *const Table, source: Source, id: *const anyopaque) bool {
    if (t.own[@backingInt(source)]) |declared| if (declared.id == id) return true;
    for (t.chain) |declared| {
        if (declared.source == source and declared.dto.id == id) return true;
    }
    return false;
}

/// Whether the route declares a response of `status` with a body of
/// `media`, or without one for null.
fn allowsAnswer(t: *const Table, status: u16, media: ?[]const u8) bool {
    for (t.responses) |a| {
        if (a.status == status and sameMedia(status, a.media, media)) return true;
    }
    if (!sameMedia(status, t.error_media, media)) return false;
    const list = t.errors orelse return true;
    for (list) |err| {
        if (t.statusOf(err) == status) return true;
    }
    return false;
}

/// Whether the route declares a response of `status`, whatever its body.
fn declaresStatus(t: *const Table, status: u16) bool {
    for (t.responses) |a| {
        if (a.status == status) return true;
    }
    const list = t.errors orelse return false;
    for (list) |err| {
        if (t.statusOf(err) == status) return true;
    }
    return false;
}

/// Whether a body of `actual` is one of `declared`: 204 and 304 send none,
/// whatever was set.
fn sameMedia(status: u16, declared: ?[]const u8, actual: ?[]const u8) bool {
    if (status == 204 or status == 304) return true;
    const d = declared orelse return actual == null;
    const a = actual orelse return false;
    return std.ascii.eqlIgnoreCase(d, a);
}

/// What a line of the check is about.
const What = union(enum) { mismatch: Mismatch, answer: Answer };

/// Logs the line of `what` for the route of `ctx`.
fn report(ctx: *Context, route: Checked, what: What) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // A line too long for the buffer is cut.
    writeLine(&w, route, what) catch {};
    const line = w.buffered();
    log.warn("{s}", .{line});
    if (builtin.is_test) seen.add(ctx.io(), line);
}

/// `zefir.http: <METHOD> <pattern> (<Controller>.<method>) <what>`.
fn writeLine(w: *std.Io.Writer, route: Checked, what: What) std.Io.Writer.Error!void {
    const info = route.info;
    const t = route.table;
    try w.print("zefir.http: {t} {s} ({s}.{s}) ", .{ info.method, info.pattern, info.controller, info.handler });
    switch (what) {
        .mismatch => |m| switch (m) {
            .input => |in| {
                try w.print("reads the {t} as {s}, but ", .{ in.source, in.read });
                if (t.own[@backingInt(in.source)]) |declared|
                    try w.print("declares .{t} = {s}", .{ in.source, declared.name })
                else
                    try w.print("declares no .{t}", .{in.source});
                var first = true;
                for (t.chain) |declared| {
                    if (declared.source != in.source) continue;
                    try w.writeAll(if (first) "; its middleware declare " else ", ");
                    first = false;
                    try w.print(".{t} = {s} ({s})", .{ declared.source, declared.dto.name, declared.by });
                }
            },
            .events => |name| {
                try w.print("subscribes with an http.sse.Manager({s}), but declares ", .{name});
                if (t.events) |declared| try w.print(".events = {s}", .{declared.name}) else try w.writeAll("no .events");
            },
        },
        .answer => |a| {
            try w.print("answered {d}", .{a.status});
            // Its status is declared, with another body.
            if (declaresStatus(t, a.status)) {
                if (a.media) |media| try w.print(" as {s}", .{media}) else try w.writeAll(" without a body");
            }
            try w.writeAll(", which it does not declare in .responses");
        },
    }
}

/// The lines of the check, for the tests of this file: how many there were,
/// and the last one.
const seen = struct {
    var mutex: std.Io.Mutex = .init;
    var count: u32 = 0;
    var last: [1024]u8 = undefined;
    var len: usize = 0;

    fn add(io: std.Io, line: []const u8) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        count += 1;
        len = line.len;
        @memcpy(last[0..len], line);
    }

    /// The lines since the last call: how many, and a copy of the last one
    /// in `out`.
    fn take(io: std.Io, out: []u8) struct { count: u32, line: []const u8 } {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const n = @min(len, out.len);
        @memcpy(out[0..n], last[0..n]);
        defer count = 0;
        return .{ .count = count, .line = out[0..n] };
    }
};

const testing = std.testing;
const sse = @import("sse.zig");
const Json = @import("dto.zig").Json;

// Application code of the tests: zefir-http ships no controller.
const TodoPath = struct { id: u64 };
const ListQuery = struct { page: u32 = 1 };
const CreateTodo = struct { title: []const u8 };
const Todo = struct {
    id: u64,
    title: []const u8,
    pub const field_rules = .{ .title = @import("validator").transformWith(refuseEmpty) };
};
const Conflict = struct { code: []const u8 };
const TodoEvent = union(enum) { created: Todo };

fn refuseEmpty(_: std.mem.Allocator, title: []const u8) error{EmptyTitle}![]const u8 {
    if (title.len == 0) return error.EmptyTitle;
    return title;
}

/// A controller of the document: the check compares its routes.
const TodosV1Controller = struct {
    pub const openapi = .{};

    const List = routes.get("", .{ .query = ListQuery });
    const Create = routes.post("", .{ .body = CreateTodo, .responses = .{
        .created = .{},
        .see_other = .{},
        .conflict = .{ .json = Conflict },
        .ok = .{ .content_type = "text/csv; charset=utf-8" },
    } });
    const Remove = routes.delete("/{id}", .{ .path = TodoPath });
    const Events = sse.get("/events", .{ .events = TodoEvent });

    pub fn list(_: *TodosV1Controller, _: *Context) error{TodoListGone}!Json(Todo) {
        return error.TodoListGone;
    }
    pub fn create(_: *TodosV1Controller, _: *Context) !Json(Todo) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" }, .status = 201 };
    }
    pub fn remove(_: *TodosV1Controller, _: *Context) !void {}
    pub fn events(_: *TodosV1Controller, _: *sse.Context) !void {}
};

/// A controller outside the document: no table.
const HealthController = struct {
    pub fn check(_: *HealthController, _: *Context) !void {}
};

const ApiError = struct { code: []const u8 };

const AppErrors = struct {
    pub fn mapError(err: anyerror) errors.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoListGone => .{ .status = 410, .body = .{ .code = "todos.gone" } },
            else => .fallback(err, .{ .code = errors.defaultCode(err) }),
        };
    }
};

fn findError(list: []const anyerror, err: anyerror) bool {
    for (list) |e| {
        if (e == err) return true;
    }
    return false;
}

test "tableOf: what a route declares of its input, its errors and their answers" {
    if (!enabled) return error.SkipZigTest;
    const t = comptime tableOf(TodosV1Controller, "list", TodosV1Controller.List, &.{}, AppErrors).?;
    // The DTO of its query; the other sources are not declared.
    try testing.expectEqual(idOf(ListQuery), t.own[@backingInt(Source.query)].?.id);
    try testing.expectEqualStrings("ListQuery", t.own[@backingInt(Source.query)].?.name);
    try testing.expectEqual(null, t.own[@backingInt(Source.path)]);
    try testing.expect(idOf(ListQuery) != idOf(TodoPath));
    // A JSON route without .responses: 200 with its value.
    try testing.expectEqual(1, t.responses.len);
    try testing.expectEqual(200, t.responses[0].status);
    try testing.expectEqualStrings("application/json", t.responses[0].media.?);
    // The errors of its handler and of the transforms of its value, which
    // mapError answers in the error handler's media type.
    try testing.expect(findError(t.errors.?, error.TodoListGone) and findError(t.errors.?, error.EmptyTitle));
    try testing.expect(!findError(t.errors.?, error.RequestTimeout));
    try testing.expectEqual(410, t.statusOf(error.TodoListGone));
    try testing.expectEqual(500, t.statusOf(error.EmptyTitle));
    try testing.expectEqualStrings("application/json", t.error_media);
    try testing.expectEqual(null, t.events);
}

test "tableOf: .responses as declared, a void route's 204, an SSE route's stream and events" {
    if (!enabled) return error.SkipZigTest;
    const create = comptime tableOf(TodosV1Controller, "create", TodosV1Controller.Create, &.{}, errors.DefaultErrors).?;
    const want = [_]struct { u16, ?[]const u8 }{
        // .{} on a 2xx of a JSON route: its value.
        .{ 201, "application/json" },
        // .{} elsewhere: no body.
        .{ 303, null },
        .{ 409, "application/json" },
        // A media type without its parameters.
        .{ 200, "text/csv" },
    };
    try testing.expectEqual(want.len, create.responses.len);
    for (want, create.responses) |w, r| {
        try testing.expectEqual(w[0], r.status);
        if (w[1]) |media| try testing.expectEqualStrings(media, r.media.?) else try testing.expectEqual(null, r.media);
    }
    try testing.expectEqual(idOf(CreateTodo), create.own[@backingInt(Source.body)].?.id);
    // The default handler answers with http.Problem.
    try testing.expectEqualStrings("application/problem+json", create.error_media);

    const remove = comptime tableOf(TodosV1Controller, "remove", TodosV1Controller.Remove, &.{}, errors.DefaultErrors).?;
    try testing.expectEqual(204, remove.responses[0].status);
    try testing.expectEqual(null, remove.responses[0].media);
    try testing.expectEqual(idOf(TodoPath), remove.own[@backingInt(Source.path)].?.id);

    const events = comptime tableOf(TodosV1Controller, "events", TodosV1Controller.Events, &.{}, errors.DefaultErrors).?;
    try testing.expectEqual(200, events.responses[0].status);
    try testing.expectEqualStrings("text/event-stream", events.responses[0].media.?);
    try testing.expectEqual(idOf(TodoEvent), events.events.?.id);
}

test "tableOf: a controller without openapi has no table" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectEqual(null, comptime tableOf(HealthController, "check", routes.get("/health", .{}), &.{}, errors.DefaultErrors));
}

test "mediaType: a media type without its parameters" {
    try testing.expectEqualStrings("text/csv", mediaType("text/csv; charset=utf-8"));
    try testing.expectEqualStrings("application/json", mediaType("application/json"));
    try testing.expectEqualStrings("text/html", mediaType(" text/html ;q=1"));
}

// The check through the server, on `http.testing`.

const Server = @import("Server.zig");
const TestingBackend = @import("testing/Backend.zig");

const Item = struct { id: u64, title: []const u8 };
const ItemEvent = union(enum) { created: Item };
const OtherEvent = union(enum) { other: u32 };
const OtherQuery = struct { q: ?[]const u8 = null };
const PageQuery = struct { limit: u32 = 20 };
const TokenHeaders = struct { authorization: ?[]const u8 = null };

/// The form of `zefir.openapi.MiddlewareDoc`, as far as the check reads it:
/// types, `void` for none, and a field per status of `std.http.Status`,
/// null for none.
const TypedDoc = struct {
    query: type = void,
    headers: type = void,
    cookies: type = void,
    responses: Responses = .{},

    const Response = struct { description: ?[]const u8 = null, content_type: ?[]const u8 = null, json: type = void };
    const Responses = ResponsesOf(Response);
};

fn ResponsesOf(comptime Response: type) type {
    const names = @typeInfo(std.http.Status).@"enum".field_names;
    const none: ?Response = null;
    return @Struct(.auto, null, names, &@as([names.len]type, @splat(?Response)), &@as([names.len]std.lang.Type.Struct.FieldAttributes, @splat(.{ .default_value_ptr = &none })));
}

/// A middleware type, whose `openapi` is a literal: it reads a query of its
/// own, and answers 304 itself when asked, or a 418 nobody declares.
const Paging = struct {
    pub const openapi = .{ .query = PageQuery, .responses = .{ .not_modified = .{} } };

    pub fn run(ctx: *Context) !mw.MiddlewareResult {
        _ = try ctx.query(PageQuery);
        if (is(ctx, "not modified")) {
            _ = ctx.response.status(304);
            return .handled;
        }
        if (is(ctx, "teapot")) {
            _ = ctx.response.status(418);
            return .handled;
        }
        return .next;
    }
};

/// A middleware object of the server, whose `openapi` is typed: it reads
/// the headers of every request, before the route is applied, and answers
/// a page of its own when asked.
const TokenCheck = struct {
    pub const openapi: TypedDoc = .{
        .headers = TokenHeaders,
        .responses = .{ .unauthorized = .{ .description = "Signs in.", .content_type = "text/html; charset=utf-8" } },
    };

    pub fn run(_: *TokenCheck, ctx: *Context) !mw.MiddlewareResult {
        _ = try ctx.headers(TokenHeaders);
        if (!is(ctx, "login page")) return .next;
        try ctx.response.status(401).html("<p>Sign in</p>");
        return .handled;
    }
};

/// What the test asks of a handler, in the header `x-mode`, which the
/// handler reads raw: the check does not compare raw reads.
fn is(ctx: *const Context, mode: []const u8) bool {
    return std.mem.eql(u8, ctx.request.header("x-mode") orelse "", mode);
}

/// A controller of the document, whose handlers keep to what their routes
/// declare unless `x-mode` asks otherwise.
const ItemsV1Controller = struct {
    live: *sse.Manager(ItemEvent),
    other: *sse.Manager(OtherEvent),

    pub const openapi = .{};

    const Create = routes.post("", .{ .body = CreateTodo, .responses = .{ .created = .{}, .ok = .{} } });

    pub const http_routes = routes.routes(.{
        .prefix = "/v1/items",
        .methods = .{
            .list = routes.get("", .{ .query = ListQuery }),
            .get = routes.get("/{id}", .{ .path = TodoPath }),
            .create = Create,
            .remove = routes.delete("/{id}", .{ .path = TodoPath }),
            .exportCsv = routes.get("/export.csv", .{ .responses = .{ .ok = .{ .content_type = "text/csv" } } }),
            .events = sse.get("/events", .{ .events = ItemEvent }),
            .page = routes.get("/page", .{ .middleware = .{Paging} }),
        },
    });

    pub fn page(_: *ItemsV1Controller, ctx: *Context) !void {
        if (is(ctx, "other query")) _ = try ctx.query(OtherQuery) else _ = try ctx.query(PageQuery);
    }

    pub fn list(_: *ItemsV1Controller, ctx: *Context) !Json(Item) {
        if (is(ctx, "other query")) _ = try ctx.query(OtherQuery) else _ = try ctx.query(ListQuery);
        if (is(ctx, "path")) _ = try ctx.path(TodoPath);
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }

    pub fn get(_: *ItemsV1Controller, ctx: *Context) !Json(Item) {
        const path = try ctx.path(TodoPath);
        if (is(ctx, "missing") or is(ctx, "html") or is(ctx, "410")) return error.TodoNotFound;
        return .{ .value = .{ .id = path.id, .title = "Buy milk" }, .status = if (is(ctx, "201")) 201 else 200 };
    }

    pub fn create(_: *ItemsV1Controller, ctx: *Context) !Json(Item) {
        if (is(ctx, "form")) _ = try ctx.form(CreateTodo);
        const in = try ctx.input(Create);
        return .{ .value = .{ .id = 2, .title = in.body.title }, .status = if (is(ctx, "202")) 202 else 201 };
    }

    pub fn remove(_: *ItemsV1Controller, ctx: *Context) !void {
        _ = try ctx.path(TodoPath);
        if (is(ctx, "text")) try ctx.response.text("gone");
        if (is(ctx, "redirect")) try ctx.response.status(303).redirect("/");
    }

    pub fn exportCsv(_: *ItemsV1Controller, ctx: *Context) !void {
        var out = try ctx.response.stream(.{ .content_type = if (is(ctx, "html")) "text/html" else "text/csv; charset=utf-8" });
        try out.writeAll("id,title\n1,Buy milk\n");
        try out.finish();
    }

    pub fn events(self: *ItemsV1Controller, ctx: *sse.Context) !void {
        if (is(ctx.internal.http, "other events")) {
            _ = try self.other.subscribe(ctx, "items");
            return;
        }
        _ = try self.live.subscribe(ctx, "items");
    }
};

/// A controller outside the document: the same mistakes go unchecked.
const PlainV1Controller = struct {
    pub const http_routes = routes.routes(.{
        .prefix = "/v1/plain",
        .methods = .{
            .list = routes.get("", .{ .query = ListQuery }),
            .get = routes.get("/{id}", .{}),
        },
    });

    pub fn list(_: *PlainV1Controller, ctx: *Context) !Json(Item) {
        _ = try ctx.query(OtherQuery);
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }

    pub fn get(_: *PlainV1Controller, _: *Context) !Json(Item) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" }, .status = 201 };
    }
};

/// Maps the errors of the controllers; `handle` answers in HTML, or with
/// another status, when `x-mode` asks.
const ItemErrors = struct {
    pub fn mapError(err: anyerror) errors.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .code = "items.not_found" } },
            else => .fallback(err, .{ .code = errors.defaultCode(err) }),
        };
    }

    pub fn handle(_: *ItemErrors, ctx: *Context, err: anyerror, res: *errors.ErrorResponse(ApiError)) !errors.ErrorAction {
        if (err != error.TodoNotFound) return .respond;
        if (is(ctx, "410")) res.status = 410;
        if (!is(ctx, "html")) return .respond;
        try ctx.response.status(404).html("<p>Not found</p>");
        return .handled;
    }
};

/// A server of both controllers, under "/api"; it stays where `start` put
/// it.
const CheckFixture = struct {
    live: sse.Manager(ItemEvent) = undefined,
    other: sse.Manager(OtherEvent) = undefined,
    items: ItemsV1Controller = undefined,
    plain: PlainV1Controller = .{},
    token_check: TokenCheck = .{},
    item_errors: ItemErrors = .{},
    backend: TestingBackend = undefined,
    server: Server = undefined,
    /// The last line of the check, copied.
    line: [1024]u8 = undefined,

    fn start(f: *CheckFixture) !void {
        const io = testing.io;
        f.live = .init(testing.allocator, .{});
        errdefer f.live.deinit(io);
        f.other = .init(testing.allocator, .{});
        errdefer f.other.deinit(io);
        f.items = .{ .live = &f.live, .other = &f.other };
        f.backend = .init(testing.allocator);
        errdefer f.backend.deinit();
        f.server = try Server.init(testing.allocator, .{
            .backend = f.backend.backend(),
            .prefix = "/api",
            .controllers = .{ &f.items, &f.plain },
            .middleware = .{&f.token_check},
            .error_handler = &f.item_errors,
        });
        errdefer f.server.deinit(io);
        try f.server.start(io);
        // The lines of the tests before.
        _ = seen.take(io, &f.line);
    }

    fn stop(f: *CheckFixture) void {
        const io = testing.io;
        f.server.deinit(io);
        f.other.deinit(io);
        f.live.deinit(io);
        f.backend.deinit();
    }

    /// A request with `x-mode: mode` and a JSON body when there is one.
    fn request(f: *CheckFixture, method: std.http.Method, target: []const u8, mode: []const u8, body: []const u8) !TestingBackend.Response {
        return f.backend.request(testing.io, .{
            .method = method,
            .target = target,
            .headers = &.{ .{ "x-mode", mode }, .{ "content-type", "application/json" } },
            .body = body,
        });
    }

    /// The request gets the server's own 500 problem+json, and the check
    /// logs `line`, once.
    fn expectRefused(f: *CheckFixture, method: std.http.Method, target: []const u8, mode: []const u8, line: []const u8) !void {
        var res = try f.request(method, target, mode, if (method == .POST) "{\"title\":\"Buy milk\"}" else "");
        defer res.deinit();
        errdefer std.debug.print("{t} {s} with x-mode {s}: {d} {s}\n", .{ method, target, mode, res.status, res.body });
        try testing.expectEqual(500, res.status);
        try testing.expect(!res.aborted);
        try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
        try testing.expectEqualStrings("{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500,\"code\":\"internal\",\"errors\":[]}", res.body);
        try f.expectLine(line);
    }

    /// The request gets `status`, and the check logs nothing.
    fn expectPassed(f: *CheckFixture, method: std.http.Method, target: []const u8, mode: []const u8, status: u16) !void {
        var res = try f.request(method, target, mode, if (method == .POST) "{\"title\":\"Buy milk\"}" else "");
        defer res.deinit();
        errdefer std.debug.print("{t} {s} with x-mode {s}: {d} {s}\n", .{ method, target, mode, res.status, res.body });
        try testing.expectEqual(status, res.status);
        try f.expectLine(null);
    }

    fn expectLine(f: *CheckFixture, line: ?[]const u8) !void {
        const got = seen.take(testing.io, &f.line);
        if (line) |want| {
            try testing.expectEqual(1, got.count);
            try testing.expectEqualStrings(want, got.line);
        } else {
            if (got.count != 0) std.debug.print("unexpected line: {s}\n", .{got.line});
            try testing.expectEqual(0, got.count);
        }
    }
};

test "check: the calls and the answers a route declares pass" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    try f.expectPassed(.GET, "/api/v1/items", "", 200);
    try f.expectPassed(.GET, "/api/v1/items/1", "", 200);
    // HEAD of a GET: its answer without the body.
    try f.expectPassed(.HEAD, "/api/v1/items/1", "", 200);
    try f.expectPassed(.POST, "/api/v1/items", "", 201);
    try f.expectPassed(.DELETE, "/api/v1/items/1", "", 204);
    try f.expectPassed(.GET, "/api/v1/items/export.csv", "", 200);
    // An error of the route, answered by mapError.
    try f.expectPassed(.GET, "/api/v1/items/1", "missing", 404);
    try f.expectPassed(.GET, "/api/v1/items/0x", "", 422);
    // The stream of the route's events.
    const s = try f.backend.open(testing.io, .{ .method = .GET, .target = "/api/v1/items/events" });
    defer s.deinit(testing.io);
    try testing.expectEqual(200, s.status);
    try testing.expectEqualStrings("text/event-stream", s.header("content-type").?);
    try f.expectLine(null);
}

test "check: an input call of another type, or of a source the route does not declare, is a 500 with its line" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err; // the lines are warnings
    defer testing.log_level = level;

    try f.expectRefused(.GET, "/api/v1/items", "other query", "zefir.http: GET /api/v1/items (ItemsV1Controller.list) reads the query as OtherQuery, but declares .query = ListQuery");
    try f.expectRefused(.GET, "/api/v1/items", "path", "zefir.http: GET /api/v1/items (ItemsV1Controller.list) reads the path as TodoPath, but declares no .path");
    // The form fails with 415, which the route answers; its read is the
    // mismatch all the same.
    try f.expectRefused(.POST, "/api/v1/items", "form", "zefir.http: POST /api/v1/items (ItemsV1Controller.create) reads the form as CreateTodo, but declares no .form");
}

test "check: a status or a body the route does not declare is a 500 with its line" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    try f.expectRefused(.GET, "/api/v1/items/1", "201", "zefir.http: GET /api/v1/items/{id} (ItemsV1Controller.get) answered 201, which it does not declare in .responses");
    try f.expectRefused(.POST, "/api/v1/items", "202", "zefir.http: POST /api/v1/items (ItemsV1Controller.create) answered 202, which it does not declare in .responses");
    try f.expectRefused(.DELETE, "/api/v1/items/1", "text", "zefir.http: DELETE /api/v1/items/{id} (ItemsV1Controller.remove) answered 200, which it does not declare in .responses");
    try f.expectRefused(.DELETE, "/api/v1/items/1", "redirect", "zefir.http: DELETE /api/v1/items/{id} (ItemsV1Controller.remove) answered 303, which it does not declare in .responses");
    // A stream whose head did not go out: the 500 in its place, whole.
    try f.expectRefused(.GET, "/api/v1/items/export.csv", "html", "zefir.http: GET /api/v1/items/export.csv (ItemsV1Controller.exportCsv) answered 200 as text/html, which it does not declare in .responses");
}

test "check: what the error handler's handle changes is compared too" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    try f.expectRefused(.GET, "/api/v1/items/1", "html", "zefir.http: GET /api/v1/items/{id} (ItemsV1Controller.get) answered 404 as text/html, which it does not declare in .responses");
    try f.expectRefused(.GET, "/api/v1/items/1", "410", "zefir.http: GET /api/v1/items/{id} (ItemsV1Controller.get) answered 410, which it does not declare in .responses");
}

test "check: subscribe with a manager of other events is a 500 with its line" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    try f.expectRefused(.GET, "/api/v1/items/events", "other events", "zefir.http: GET /api/v1/items/events (ItemsV1Controller.events) subscribes with an http.sse.Manager(OtherEvent), but declares .events = ItemEvent");
    // No stream opened.
    try testing.expectEqual(0, @import("testing.zig").openStreams(&f.server));
}

test "tableOf: the openapi of the middleware of the chain, a literal or typed, read by the names of its fields" {
    if (!enabled) return error.SkipZigTest;
    const chain = comptime mw.unfold(@TypeOf(.{ Paging, @as(*TokenCheck, undefined) }), .{ .level = .global }, &.{});
    const t = comptime tableOf(TodosV1Controller, "remove", TodosV1Controller.Remove, chain, errors.DefaultErrors).?;
    try testing.expectEqual(2, t.chain.len);
    try testing.expectEqual(Source.query, t.chain[0].source);
    try testing.expectEqual(idOf(PageQuery), t.chain[0].dto.id);
    try testing.expectEqualStrings("Paging", t.chain[0].by);
    try testing.expectEqual(Source.headers, t.chain[1].source);
    try testing.expectEqualStrings("TokenHeaders", t.chain[1].dto.name);
    try testing.expectEqualStrings("TokenCheck", t.chain[1].by);
    // The route's 204, then the middleware's: a 304 without a body, and of
    // all the statuses of the typed one, the 401 it declares.
    try testing.expectEqual(3, t.responses.len);
    try testing.expectEqual(304, t.responses[1].status);
    try testing.expectEqual(null, t.responses[1].media);
    try testing.expectEqual(401, t.responses[2].status);
    try testing.expectEqualStrings("text/html", t.responses[2].media.?);
}

test "check: the input and the answers that the middleware of the chain declare pass; others do not" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    // Paging's query and TokenCheck's headers, read on every request.
    try f.expectPassed(.GET, "/api/v1/items/page", "", 204);
    try f.expectPassed(.GET, "/api/v1/items/page", "not modified", 304);
    try f.expectPassed(.GET, "/api/v1/items/1", "login page", 401);
    try f.expectRefused(.GET, "/api/v1/items/page", "teapot", "zefir.http: GET /api/v1/items/page (ItemsV1Controller.page) answered 418, which it does not declare in .responses");
    try f.expectRefused(.GET, "/api/v1/items/page", "other query", "zefir.http: GET /api/v1/items/page (ItemsV1Controller.page) reads the query as OtherQuery, but declares no .query; its middleware declare .query = PageQuery (Paging)");
}

test "check: the routes of a controller without openapi are not checked" {
    if (!enabled) return error.SkipZigTest;
    var f: CheckFixture = .{};
    try f.start();
    defer f.stop();

    try f.expectPassed(.GET, "/api/v1/plain", "", 200);
    try f.expectPassed(.GET, "/api/v1/plain/1", "", 201);
}
