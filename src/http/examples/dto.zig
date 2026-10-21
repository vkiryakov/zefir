//! The DTOs of /api/v1/todos: what a request brings in and what a response
//! sends out. The `field_rules` of a field hold, in this order, its outside
//! name (`v.rename`), its transforms and its rules; zefir-http reads the
//! input by them and writes the output by them.

const std = @import("std");
const v = @import("validator");
const TodoRepository = @import("TodoRepository.zig");

/// In JSON and in a query: "low", "normal" or "high".
pub const Priority = TodoRepository.Priority;

// ---------- Requests ----------

/// The path of /v1/todos/{id}: the field `id` reads the parameter `{id}`.
pub const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };
};

/// The query of GET /v1/todos, such as
/// `?done=false&page=2&perPage=50&tags=home,shop&q=milk`. Parameters it
/// does not name are ignored: proxies and analytics add their own.
pub const ListTodosQuery = struct {
    /// No parameter: done or not.
    done: ?bool = null,
    page: u32 = 1,
    per_page: u32 = 20,
    tags: []const []const u8 = &.{},
    /// Words of the title.
    q: ?[]const u8 = null,

    pub const field_rules = .{
        .page = v.range(1, 10_000),
        .per_page = .{ v.rename("perPage"), v.range(1, 100) },
        // ?tags=home&tags=shop or ?tags=home,shop: a list either way.
        .tags = v.transformWith(splitComma),
        // A transform runs on the value of an optional field when it is there.
        .q = .{ v.trim, v.toLower, v.maxLength(100) },
    };
};

/// Each item of `value` split at its commas, without empty parts.
fn splitComma(arena: std.mem.Allocator, value: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (value) |item| {
        var it = std.mem.tokenizeScalar(u8, item, ',');
        while (it.next()) |part| try parts.append(arena, part);
    }
    return parts.items;
}

/// The headers of POST /v1/todos: the field `idempotency_key` is the header
/// `Idempotency-Key`. A client that sends the same key again, after a
/// timeout say, gets the todo it made the first time instead of a second
/// one.
pub const CreateTodoHeaders = struct {
    idempotency_key: ?[]const u8 = null,

    pub const field_rules = .{ .idempotency_key = .{ v.trim, v.notBlank, v.maxLength(64) } };
};

/// The body of POST /v1/todos. A field it does not name is refused:
/// `{"titel": …}` is a 422.
pub const CreateTodoRequest = struct {
    title: []const u8,
    priority: Priority = .normal,
    due_date: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    // The transforms run before the rules: notBlank and maxLength see the
    // trimmed title.
    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
        .due_date = .{ v.rename("dueDate"), v.trim, v.date },
        .tags = v.each(.{ v.trim, v.toLower, v.notBlank, v.maxLength(30) }),
    };
};

/// The body of PATCH /v1/todos/{id}: a field that is not sent stays as it
/// is. A missing field and `null` read the same, so a due date can be
/// changed but not removed this way.
pub const UpdateTodoRequest = struct {
    title: ?[]const u8 = null,
    done: ?bool = null,
    priority: ?Priority = null,
    due_date: ?[]const u8 = null,

    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
        .due_date = .{ v.rename("dueDate"), v.trim, v.date },
    };
};

// ---------- Responses ----------

/// One todo, as the API shows it: the owner and the idempotency key of the
/// stored todo stay inside.
pub const TodoResponse = struct {
    id: u64,
    title: []const u8,
    done: bool,
    priority: Priority,
    due_date: ?[]const u8,
    tags: []const []const u8,

    // The outside names hold for the output too.
    pub const field_rules = .{ .due_date = v.rename("dueDate") };

    pub fn from(todo: TodoRepository.Todo) TodoResponse {
        return .{ .id = todo.id, .title = todo.title, .done = todo.done, .priority = todo.priority, .due_date = todo.due_date, .tags = todo.tags };
    }
};

/// A page of the list.
pub const TodoListResponse = struct {
    items: []const TodoResponse,
    page: u32,
    per_page: u32,
    total: u64,

    pub const field_rules = .{ .per_page = v.rename("perPage") };

    /// `arena` is the request's: what it gives is freed with the request.
    pub fn from(arena: std.mem.Allocator, page: TodoRepository.Page, query: ListTodosQuery) error{OutOfMemory}!TodoListResponse {
        const items = try arena.alloc(TodoResponse, page.items.len);
        for (items, page.items) |*item, todo| item.* = .from(todo);
        return .{ .items = items, .page = query.page, .per_page = query.per_page, .total = page.total };
    }
};

// ---------- Events ----------

/// The events of the stream of live updates, /v1/todos/events: the name of
/// a variant is the name of its event, and its value is the data, written
/// as JSON as a response is.
pub const LiveEvent = union(enum) {
    @"todo.created": TodoResponse,
    @"todo.updated": TodoResponse,
    @"todo.deleted": TodoIdPath,
};
