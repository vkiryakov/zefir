//! What build.zig compiles for the compile checks of zefir-openapi, read
//! by `addOpenapiCompileChecks`. Paths are relative to the repository root
//! and stay inside `src/`, the part of the package that `build.zig.zon`
//! ships, since a client's build runs zefir's build.zig too. Each file is
//! application code: it imports "zefir", declares its types with their
//! `pub const openapi`, and references those in a `test` block, since Zig
//! compiles only what is used.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

/// Files in src/openapi/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // The compiler's own errors: the declarations are typed, so a mistake
    // in one is an ordinary error of Zig at the line of the application.
    .{ .file = dir ++ "doc_key_typo.zig", .expect = "no field named 'descripton' in struct 'openapi.FieldDoc(u64)'" },
    .{ .file = dir ++ "doc_field_typo.zig", .expect = "no field named 'titel' in struct 'openapi.Doc(doc_field_typo.CreateTodoRequest).Fields'" },
    .{ .file = dir ++ "doc_constraint_key.zig", .expect = "no field named 'maxLength' in struct 'openapi.FieldDoc([]const u8)'" },
    .{ .file = dir ++ "doc_example_type.zig", .expect = "expected type '[]const u8', found 'comptime_int'" },
    .{ .file = dir ++ "doc_enum_values.zig", .expect = "no field named 'values' in struct 'openapi.Doc(doc_enum_values.Priority)'" },
    .{ .file = dir ++ "doc_as_missing.zig", .expect = "missing struct field: as" },
    .{ .file = dir ++ "controller_route_missing.zig", .expect = "missing struct field: exportCsv" },
    .{ .file = dir ++ "controller_summary_missing.zig", .expect = "missing struct field: summary" },
    .{ .file = dir ++ "controller_status_unknown.zig", .expect = "no field named 'created' in struct 'openapi.RouteDoc(controller_status_unknown.TodosController,\"get\"[0..3]).Responses'" },
    .{ .file = dir ++ "middleware_key_typo.zig", .expect = "no field named 'securty' in struct 'openapi.MiddlewareDoc'" },
};

const dir = "src/openapi/tests/compile_errors/";
