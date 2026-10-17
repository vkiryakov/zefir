const std = @import("std");
const http = @import("http");
const v = @import("validator");

const Todo = struct { id: u64, title: []const u8 };

// The body of POST: the title is trimmed, then checked.
const NewTodo = struct {
    title: []const u8,

    pub const field_rules = .{ .title = .{ v.trim, v.notBlank, v.maxLength(200) } };
};

// A controller: the routes it declares, and a method for each.
const TodosV1Controller = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{
            .list = http.get("", .{}),
            .create = http.post("", .{}),
        },
    });

    pub fn list(self: *TodosV1Controller, ctx: *http.Context) !http.Json([]const Todo) {
        try self.mutex.lock(ctx.io());
        defer self.mutex.unlock(ctx.io());
        return .{ .value = try ctx.allocator().dupe(Todo, self.todos.items) };
    }

    pub fn create(self: *TodosV1Controller, ctx: *http.Context) !http.Json(Todo) {
        // Parsed, trimmed and checked: a body that does not fit never gets here.
        const body = try ctx.json(NewTodo);
        try self.mutex.lock(ctx.io());
        defer self.mutex.unlock(ctx.io());
        const todo: Todo = .{ .id = self.todos.items.len + 1, .title = try self.gpa.dupe(u8, body.title) };
        try self.todos.append(self.gpa, todo);
        return .{ .value = todo, .status = 201 };
    }

    fn deinit(self: *TodosV1Controller) void {
        for (self.todos.items) |todo| self.gpa.free(todo.title);
        self.todos.deinit(self.gpa);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The backend in memory serves the server without a network; on the
    // network, http.native.Backend takes its place.
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var todos: TodosV1Controller = .{ .gpa = gpa };
    defer todos.deinit();
    var server = try http.Server.init(gpa, .{ .backend = backend.backend(), .prefix = "/api", .controllers = .{&todos} });
    defer server.deinit(io);
    try server.start(io);

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    for ([_]struct { std.http.Method, []const u8 }{
        .{ .POST, "{\"title\":\"  Buy milk  \"}" },
        .{ .POST, "{\"title\":\"   \"}" },
        .{ .GET, "" },
    }) |request| {
        const method, const body = request;
        var res = try backend.request(io, .{
            .method = method,
            .target = "/api/v1/todos",
            .headers = &.{.{ "content-type", "application/json" }},
            .body = body,
        });
        defer res.deinit();
        try out.print("{t} /api/v1/todos{s}{s}\n", .{ method, if (body.len > 0) " " else "", body });
        try out.print("→ {d} {s} {s}\n", .{ res.status, res.header("content-type").?, res.body });
    }
    try out.flush();
}
