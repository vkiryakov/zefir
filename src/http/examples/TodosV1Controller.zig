//! The REST controller of todos, version 1: /api/v1/todos. It declares its
//! routes; the compiler checks them where `main` passes the controller to
//! `http.Server.init`. Every route needs a signed-in user, and each user
//! sees only their own todos.

const std = @import("std");
const http = @import("http");
const auth = @import("auth.zig");
const dto = @import("dto.zig");
const mw = @import("middleware.zig");
const Billing = @import("Billing.zig");
const TodoRepository = @import("TodoRepository.zig");

const TodosV1Controller = @This();

// The dependencies are fields: `main` builds them and the controller.
repo: *TodoRepository,
/// The SSE streams of live updates, a key per user.
live: *http.sse.Manager,
/// A middleware object of this controller: `.plans` in the routes below.
plans: *mw.PlanLookup,

pub const http_routes = http.routes(.{
    .prefix = "/v1/todos",
    // After the server's middleware and before a route's own: the set with
    // requireUser, then the permission every route here needs.
    .middleware = .{ mw.protected, auth.requirePermission("todos") },
    .methods = .{
        .list = http.get("", .{}),
        .get = http.get("/{id}", .{}),
        .create = http.post("", .{ .middleware = .{.plans}, .max_body_bytes = 16 * 1024 }),
        .update = http.patch("/{id}", .{}),
        .delete = http.delete("/{id}", .{ .middleware = .{auth.requirePermission("todos:delete")} }),
        // A literal segment wins over {id}: /export.csv is not a todo.
        .exportCsv = http.get("/export.csv", .{ .timeout = std.Io.Duration.fromSeconds(300) }),
        .events = http.sse.get("/events", .{ .heartbeat = std.Io.Duration.fromSeconds(15), .on_close = .eventsClosed }),
    },
});

pub fn list(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoListResponse) {
    // Parsed, transformed and checked: a query that does not fit is a 422.
    const query = try ctx.query(dto.ListTodosQuery);
    const page = try self.repo.list(ctx.operation(), ctx.io(), ctx.allocator(), try owner(ctx), .{
        .done = query.done,
        .search = query.q,
        .tags = query.tags,
        .page = query.page,
        .per_page = query.per_page,
    });
    return .{ .value = try .from(ctx.allocator(), page, query) };
}

pub fn get(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) {
    const path = try ctx.path(dto.TodoIdPath);
    // No such todo: error.TodoNotFound, which AppErrors turns into a 404.
    const todo = try self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), try owner(ctx), path.id);
    return .{ .value = .from(todo) };
}

pub fn create(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) {
    const body = try ctx.json(dto.CreateTodoRequest);
    const headers = try ctx.headers(dto.CreateTodoHeaders);
    const user = try owner(ctx);
    // The same Idempotency-Key again, a retry: the todo it made, as it is.
    if (headers.idempotency_key) |key| {
        if (try self.repo.findByKey(ctx.operation(), ctx.io(), ctx.allocator(), user, key)) |todo| return .{ .value = .from(todo) };
    }
    // Put there by PlanLookup, which runs on this route only.
    const plan = try ctx.local(Billing.Plan);
    const usage = try ctx.local(mw.Usage);
    if (usage.todos >= plan.max_todos) return error.TodoLimitReached;
    const todo = try self.repo.insert(ctx.operation(), ctx.io(), ctx.allocator(), .{
        .owner = user,
        .title = body.title,
        .priority = body.priority,
        .due_date = body.due_date,
        .tags = body.tags,
        .idempotency_key = headers.idempotency_key,
    });
    try self.live.publish(ctx.operation(), ctx.io(), user, .{ .event = "todo.created", .data = dto.TodoResponse.from(todo) });
    return .{ .value = .from(todo), .status = 201 };
}

pub fn update(self: *TodosV1Controller, ctx: *http.Context) !http.Json(dto.TodoResponse) {
    const path = try ctx.path(dto.TodoIdPath);
    const body = try ctx.json(dto.UpdateTodoRequest);
    const user = try owner(ctx);
    const todo = try self.repo.update(ctx.operation(), ctx.io(), ctx.allocator(), user, path.id, .{
        .title = body.title,
        .done = body.done,
        .priority = body.priority,
        .due_date = body.due_date,
    });
    try self.live.publish(ctx.operation(), ctx.io(), user, .{ .event = "todo.updated", .data = dto.TodoResponse.from(todo) });
    return .{ .value = .from(todo) };
}

pub fn delete(self: *TodosV1Controller, ctx: *http.Context) !void {
    const path = try ctx.path(dto.TodoIdPath);
    const user = try owner(ctx);
    try self.repo.delete(ctx.operation(), ctx.io(), user, path.id);
    try self.live.publish(ctx.operation(), ctx.io(), user, .{ .event = "todo.deleted", .data = path });
    // Nothing written into the response: 204 No Content.
}

/// A streamed response: the rows go out as they are written, through a
/// buffer, and the file is never whole in memory.
pub fn exportCsv(self: *TodosV1Controller, ctx: *http.Context) !void {
    const todos = try self.repo.all(ctx.operation(), ctx.io(), ctx.allocator(), try owner(ctx));
    var out = try ctx.response.stream(.{ .content_type = "text/csv", .download_as = "todos.csv" });
    try out.writeAll("id,title,done\n");
    for (todos) |todo| {
        // A quote inside a CSV field is written twice.
        const title = try std.mem.replaceOwned(u8, ctx.allocator(), todo.title, "\"", "\"\"");
        try out.print("{d},\"{s}\",{}\n", .{ todo.id, title, todo.done });
    }
    try out.finish();
}

/// Opens the stream of live updates: an ordinary request until
/// `subscribe`, which sends the head of the stream and returns at once;
/// the stream lives on, and `publish` above writes to it.
pub fn events(self: *TodosV1Controller, ctx: *http.sse.Context) !void {
    _ = try self.live.subscribe(ctx, try owner(ctx));
}

/// Once, when the stream has ended: the client left, `close`, a queue that
/// overflowed or the stop of the server.
pub fn eventsClosed(_: *TodosV1Controller, ctx: *http.sse.Context) void {
    const user = ctx.locals.get(auth.CurrentUser) orelse return;
    std.log.scoped(.todos).info("Live updates closed for {s}", .{user.id});
}

/// The signed-in user: requireUser in the controller's middleware lets no
/// request without one reach a handler.
fn owner(ctx: anytype) error{LocalMissing}![]const u8 {
    return (try ctx.local(auth.CurrentUser)).id;
}
