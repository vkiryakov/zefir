//! The todos of the example app, kept in memory: the application's own
//! code, which knows nothing of HTTP. Like a repository on a real
//! database, each method takes the request's `core.Context`, the `std.Io`
//! it waits on, and an allocator for what it returns.

const std = @import("std");
const core = @import("core");

const TodoRepository = @This();

pub const Priority = enum { low, normal, high };

/// A stored todo; a response shows `dto.TodoResponse` instead.
pub const Todo = struct {
    id: u64,
    /// The id of the user it belongs to.
    owner: []const u8,
    title: []const u8,
    done: bool,
    priority: Priority,
    /// A date such as 2026-10-20.
    due_date: ?[]const u8,
    tags: []const []const u8,
    /// The `Idempotency-Key` of the request that made it.
    idempotency_key: ?[]const u8,
};

pub const NewTodo = struct {
    owner: []const u8,
    title: []const u8,
    priority: Priority,
    due_date: ?[]const u8,
    tags: []const []const u8,
    idempotency_key: ?[]const u8,
};

/// What `update` changes: the fields that are not null.
pub const Change = struct {
    title: ?[]const u8,
    done: ?bool,
    priority: ?Priority,
    due_date: ?[]const u8,
};

pub const Filter = struct {
    done: ?bool,
    /// In the title, without case: lower case already.
    search: ?[]const u8,
    /// The todo has every one of them.
    tags: []const []const u8,
    page: u32,
    per_page: u32,
};

pub const Page = struct { items: []const Todo, total: u64 };

/// The errors of the domain, which the error handler turns into responses,
/// and those of a request that is out of time or canceled.
pub const Error = error{ TodoNotFound, OutOfMemory } || std.Io.Cancelable || core.ContextError;

gpa: std.mem.Allocator,
/// Requests run in tasks of their own, many at once: the mutex guards the
/// list, and waits through `std.Io` like everything a handler does.
mutex: std.Io.Mutex = .init,
todos: std.ArrayList(Todo) = .empty,
next_id: u64 = 1,

pub fn init(gpa: std.mem.Allocator) TodoRepository {
    return .{ .gpa = gpa };
}

pub fn deinit(repo: *TodoRepository) void {
    for (repo.todos.items) |todo| free(repo.gpa, todo);
    repo.todos.deinit(repo.gpa);
}

/// A page of the todos of `owner` that pass `filter`, in the order they
/// were made, copied into `arena`.
pub fn list(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, owner: []const u8, filter: Filter) Error!Page {
    // A request that is out of time or canceled stops before the work.
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    var matching: std.ArrayList(Todo) = .empty;
    for (repo.todos.items) |todo| {
        if (std.mem.eql(u8, todo.owner, owner) and passes(todo, filter)) try matching.append(arena, todo);
    }
    const first = @min(@as(usize, filter.page - 1) * filter.per_page, matching.items.len);
    const shown = matching.items[first..@min(first + filter.per_page, matching.items.len)];
    const items = try arena.alloc(Todo, shown.len);
    for (shown, items) |todo, *item| item.* = try copy(arena, todo);
    return .{ .items = items, .total = matching.items.len };
}

fn passes(todo: Todo, filter: Filter) bool {
    if (filter.done) |done| if (todo.done != done) return false;
    if (filter.search) |words| if (std.ascii.findIgnoreCase(todo.title, words) == null) return false;
    for (filter.tags) |wanted| {
        for (todo.tags) |tag| {
            if (std.mem.eql(u8, tag, wanted)) break;
        } else return false;
    }
    return true;
}

/// The todo `id` of `owner`, copied into `arena`: once the mutex is
/// released, another request may change the stored one.
pub fn find(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, owner: []const u8, id: u64) Error!Todo {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    return copy(arena, (repo.at(owner, id) orelse return error.TodoNotFound).*);
}

/// The todo of `owner` that a request with `key` made, if one did.
pub fn findByKey(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, owner: []const u8, key: []const u8) Error!?Todo {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    for (repo.todos.items) |todo| {
        const made_with = todo.idempotency_key orelse continue;
        if (std.mem.eql(u8, todo.owner, owner) and std.mem.eql(u8, made_with, key)) return try copy(arena, todo);
    }
    return null;
}

/// How many todos `owner` has.
pub fn count(repo: *TodoRepository, ctx: core.Context, io: std.Io, owner: []const u8) (std.Io.Cancelable || core.ContextError)!u32 {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    var n: u32 = 0;
    for (repo.todos.items) |todo| {
        if (std.mem.eql(u8, todo.owner, owner)) n += 1;
    }
    return n;
}

/// Stores a new todo; the todo returned lives in `arena`.
pub fn insert(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, new: NewTodo) Error!Todo {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    const todo: Todo = .{
        .id = repo.next_id,
        .owner = new.owner,
        .title = new.title,
        .done = false,
        .priority = new.priority,
        .due_date = new.due_date,
        .tags = new.tags,
        .idempotency_key = new.idempotency_key,
    };
    const stored = try copy(repo.gpa, todo);
    errdefer free(repo.gpa, stored);
    try repo.todos.append(repo.gpa, stored);
    repo.next_id += 1;
    return copy(arena, todo);
}

/// Changes the todo `id` of `owner`; the todo returned lives in `arena`.
pub fn update(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, owner: []const u8, id: u64, change: Change) Error!Todo {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    const stored = repo.at(owner, id) orelse return error.TodoNotFound;
    var changed = stored.*;
    if (change.title) |title| changed.title = title;
    if (change.done) |done| changed.done = done;
    if (change.priority) |priority| changed.priority = priority;
    if (change.due_date) |due_date| changed.due_date = due_date;
    const kept = try copy(repo.gpa, changed);
    free(repo.gpa, stored.*);
    stored.* = kept;
    return copy(arena, kept);
}

pub fn delete(repo: *TodoRepository, ctx: core.Context, io: std.Io, owner: []const u8, id: u64) Error!void {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    for (repo.todos.items, 0..) |todo, i| {
        if (todo.id == id and std.mem.eql(u8, todo.owner, owner)) {
            free(repo.gpa, repo.todos.orderedRemove(i));
            return;
        }
    }
    return error.TodoNotFound;
}

/// Every todo of `owner`, copied into `arena`: for the export, which writes
/// them to the client after the mutex is released. A database would hand
/// the rows over as it reads them instead.
pub fn all(repo: *TodoRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, owner: []const u8) Error![]const Todo {
    try ctx.check(std.Io.Clock.awake.now(io));
    try repo.mutex.lock(io);
    defer repo.mutex.unlock(io);
    var mine: std.ArrayList(Todo) = .empty;
    for (repo.todos.items) |todo| {
        if (std.mem.eql(u8, todo.owner, owner)) try mine.append(arena, try copy(arena, todo));
    }
    return mine.items;
}

fn at(repo: *TodoRepository, owner: []const u8, id: u64) ?*Todo {
    for (repo.todos.items) |*todo| {
        if (todo.id == id and std.mem.eql(u8, todo.owner, owner)) return todo;
    }
    return null;
}

/// `todo` with every string in `allocator`.
fn copy(allocator: std.mem.Allocator, todo: Todo) error{OutOfMemory}!Todo {
    var out = todo;
    out.owner = try allocator.dupe(u8, todo.owner);
    errdefer allocator.free(out.owner);
    out.title = try allocator.dupe(u8, todo.title);
    errdefer allocator.free(out.title);
    out.due_date = if (todo.due_date) |d| try allocator.dupe(u8, d) else null;
    errdefer if (out.due_date) |d| allocator.free(d);
    out.idempotency_key = if (todo.idempotency_key) |k| try allocator.dupe(u8, k) else null;
    errdefer if (out.idempotency_key) |k| allocator.free(k);
    const tags = try allocator.alloc([]const u8, todo.tags.len);
    var done: usize = 0;
    errdefer {
        for (tags[0..done]) |tag| allocator.free(tag);
        allocator.free(tags);
    }
    for (tags, todo.tags) |*tag, given| {
        tag.* = try allocator.dupe(u8, given);
        done += 1;
    }
    out.tags = tags;
    return out;
}

fn free(allocator: std.mem.Allocator, todo: Todo) void {
    allocator.free(todo.owner);
    allocator.free(todo.title);
    if (todo.due_date) |d| allocator.free(d);
    if (todo.idempotency_key) |k| allocator.free(k);
    for (todo.tags) |tag| allocator.free(tag);
    allocator.free(todo.tags);
}
