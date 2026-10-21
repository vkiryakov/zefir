//! The Debug check of a route's declarations: on a route
//! of a controller with `pub const openapi`, the server compares what the
//! handler, the middleware and the error handler do with what the route
//! declares, and answers a mismatch with its own 500 and a line in the log.
//!
//! At compile time `tableOf` builds what a route declares: the DTO of each
//! source of its input, the responses it answers with (its `.responses`,
//! else its default response: 200 `application/json` for `http.Json(T)`,
//! 204 for `!void`, 200 `text/event-stream` for SSE), the errors it can
//! give the error handler, whose answers `mapError` gives, and the events
//! of an SSE route. Only for controllers with `openapi`, and only in Debug
//! builds: elsewhere none of this is compiled.
const std = @import("std");
const builtin = @import("builtin");
const routes = @import("routes.zig");
const plan = @import("plan.zig");
const mw = @import("middleware.zig");
const errors = @import("errors.zig");
const describe = @import("describe.zig");

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

/// What a route of a controller with `openapi` declares, as the check
/// compares its requests with it.
pub const Table = struct {
    /// The DTO the route declares for each source, by `Source`.
    own: [@typeInfo(Source).@"enum".field_names.len]?TypeRef,
    /// The responses of the route: as `.responses` lists them, or its
    /// default response.
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
            .responses = answersOf(R, ValueOf(C, handler)),
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

const testing = std.testing;
const sse = @import("sse.zig");
const Context = @import("Context.zig");
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
