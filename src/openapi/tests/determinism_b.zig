//! The document of an application does not follow the order in which the
//! compiler met its errors: here the compiler meets the errors of the todos
//! application first in one order, and every error set that holds them
//! lists them in it; determinism_a.zig meets them in the opposite order. Both
//! compare the documents with the same files. Nor does it follow the
//! numbers the compiler gives anonymous types: here the compiler makes
//! anonymous types of no use before those of the shapes application, so
//! that its numbers of those differ from determinism_a.zig's.
const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;

const testing = std.testing;
const golden = @import("golden_options").dir ++ std.fs.path.sep_str;

test "the documents of todos are those of their files whatever order the compiler met its errors in" {
    // The first mention of these errors in the program.
    comptime {
        _ = @errorName(error.TodoArchived);
        _ = @errorName(error.TodoLocked);
        _ = @errorName(error.ListNotFound);
        _ = @errorName(error.TodoNotFound);
    }
    const todos = @import("apps/todos.zig");
    const names = @typeInfo(todos.TodoError).error_set.error_names.?;
    inline for (.{ "TodoArchived", "TodoLocked", "ListNotFound", "TodoNotFound" }, names) |want, name| try testing.expectEqualStrings(want, name);

    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var service: todos.Service = .{};
    try service.start(testing.allocator, testing.io, backend.backend());
    defer service.deinit(testing.io);
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_1, golden ++ "todos-3.1.json");
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_2, golden ++ "todos-3.2.json");
}

test "the documents of shapes are those of their files whatever anonymous types the compiler made before" {
    // Anonymous types of no use, made before those of shapes: the
    // compiler numbers the anonymous types of shapes after them.
    comptime {
        _ = @sizeOf(struct { k: u8, j: u16 });
        _ = @sizeOf(struct { m: u64 });
    }
    const shapes = @import("apps/shapes.zig");
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var service: shapes.Service = .{};
    try service.start(testing.allocator, testing.io, backend.backend());
    defer service.deinit(testing.io);
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_1, golden ++ "shapes-3.1.json");
    try zefir.openapi.testing.expectFile(testing.io, service.docs_3_2, golden ++ "shapes-3.2.json");
}
