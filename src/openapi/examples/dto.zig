//! What a request brings in and what a response sends out. Each type
//! carries the texts of the document next to its fields, in
//! `pub const openapi`; the constraints come from its `field_rules`.

const zefir = @import("zefir");
const v = zefir.validator;
const TodoRepository = @import("TodoRepository.zig");

/// The path /v1/todos/{id}: the field `id` reads the parameter `{id}`.
pub const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };

    // A DTO of a path brings the texts of its fields: each field is a
    // parameter of the document.
    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .id = .{ .description = "The id of the todo.", .example = 1 } },
    };
};

pub const TodoResponse = struct {
    id: u64,
    title: []const u8,
    done: bool,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .description = "A todo, as the API shows it.",
        .fields = .{
            .id = .{ .description = "The id of the todo." },
            .title = .{ .description = "What to do." },
            .done = .{ .description = "Whether it is done." },
        },
    };

    pub fn from(todo: TodoRepository.Todo) TodoResponse {
        return .{ .id = todo.id, .title = todo.title, .done = todo.done };
    }
};
