//! The todos, a list in memory: the application's own code, which knows
//! nothing of HTTP.

const TodoRepository = @This();

pub const Todo = struct { id: u64, title: []const u8, done: bool };

todos: []const Todo,

pub fn find(repo: *const TodoRepository, id: u64) ?Todo {
    for (repo.todos) |todo| if (todo.id == id) return todo;
    return null;
}
