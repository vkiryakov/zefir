//! The DTOs of /api/v1/todos: what a request brings in and what a response
//! sends out. The `field_rules` of a field hold, in this order, its outside
//! name (`v.rename`), its transforms and its rules; zefir-http reads the
//! input by them and writes the output by them. The texts of the OpenAPI
//! document sit next to them, in `pub const openapi`; the constraints of
//! the document come from the `field_rules`.

const std = @import("std");
const v = @import("validator");
const zefir = @import("zefir");
const TodoRepository = @import("TodoRepository.zig");

/// In JSON and in a query: "low", "normal" or "high".
pub const Priority = TodoRepository.Priority;

// ---------- Requests ----------

/// The path of /v1/todos/{id}: the field `id` reads the parameter `{id}`.
pub const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };

    // Each field of a DTO of a path, a query or the headers is a parameter
    // of the document, with these texts.
    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .id = .{ .description = "The id of the todo.", .example = 1 } },
    };
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

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{
            .done = .{ .description = "Only the todos that are done, or only those that are not; without it, both." },
            .page = .{ .description = "The page, from 1." },
            .per_page = .{ .description = "How many todos a page holds." },
            .tags = .{ .description = "Only the todos that have every one of these tags: ?tags=home&tags=shop, or ?tags=home,shop." },
            .q = .{ .description = "Only the todos whose title holds these words, in any case.", .example = "milk" },
        },
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

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .idempotency_key = .{
            .description = "Send the same key again to get the todo made the first time, not a second one.",
            .example = "3f2b9c1e-7d4a-4f0e-9a61-2c8d5b7e1f30",
        } },
    };
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

    // An example is a value of the type, so the compiler checks it, and
    // its rules too: an example that breaks them does not build.
    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A new todo of the signed-in user.",
        .example = .{ .title = "Buy milk", .due_date = "2026-10-30", .tags = &.{"home"} },
        .fields = .{
            .title = .{ .description = "What to do." },
            .priority = .{ .description = "How urgent it is." },
            .due_date = .{ .description = "The day it is due." },
            .tags = .{ .description = "Labels of the todo, to find it by." },
        },
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

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "What to change in a todo: a field that is not sent, or is null, stays as it is.",
        .example = .{ .done = true },
        .fields = .{
            .title = .{ .description = "What to do." },
            .done = .{ .description = "Whether it is done." },
            .priority = .{ .description = "How urgent it is." },
            .due_date = .{ .description = "The day it is due." },
        },
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

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A todo, as the API shows it.",
        .fields = .{
            .id = .{ .description = "The id of the todo." },
            .title = .{ .description = "What to do." },
            .done = .{ .description = "Whether it is done." },
            .priority = .{ .description = "How urgent it is." },
            .due_date = .{ .description = "The day it is due; null for none." },
            .tags = .{ .description = "Labels of the todo, in lower case." },
        },
    };

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

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A page of the todos of the signed-in user, in the order they were made.",
        .fields = .{
            .items = .{ .description = "The todos of the page." },
            .page = .{ .description = "The page, from 1." },
            .per_page = .{ .description = "How many todos a page holds." },
            .total = .{ .description = "How many todos pass the filter, on all the pages." },
        },
    };

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
