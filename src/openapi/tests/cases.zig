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
    // The checks of the document, which zefir.openapi.document makes: an
    // openapi of the wrong type, a controller without one, the names of
    // schemas, operations and tags, security, responses, parameters and
    // examples.
    .{ .file = dir ++ "doc_wrong_type.zig", .expect = "zefir.openapi: CreateTodoRequest.openapi must be of type zefir.openapi.Doc(CreateTodoRequest)" },
    .{ .file = dir ++ "controller_doc_wrong_type.zig", .expect = "zefir.openapi: TodosController.openapi must be of type zefir.openapi.ControllerDoc(TodosController)" },
    .{ .file = dir ++ "middleware_doc_wrong_type.zig", .expect = "zefir.openapi: the openapi of the middleware requireUser must be of type zefir.openapi.MiddlewareDoc" },
    .{ .file = dir ++ "controller_without_doc.zig", .expect = "zefir.openapi: HealthController has no pub const openapi: zefir.openapi.ControllerDoc(HealthController); add one, or leave it out with .exclude = &.{HealthController}" },
    .{ .file = dir ++ "schema_name_clash.zig", .expect = "zefir.openapi: schema_name_clash.v1.Item and schema_name_clash.v2.Item have one schema name, Item; give one of them another: pub const openapi: zefir.openapi.Doc(@This()) = .{ .name = \"...\" }" },
    .{ .file = dir ++ "schema_name_invalid.zig", .expect = "zefir.openapi: TodoItem.openapi.name \"Todo Item\" is not a schema name: 1 or more of A-Z, a-z, 0-9, '.', '-' and '_'" },
    .{ .file = dir ++ "schema_type_unsupported.zig", .expect = "zefir.openapi: Reading.value: f128 has no JSON Schema: a value of the document is a bool, an integer, a float of up to 64 bits, an enum, a string, a struct, a union(enum), a slice, an array, a tuple or ?T of them" },
    .{ .file = dir ++ "stringify_without_doc.zig", .expect = "zefir.openapi: Money writes itself with jsonStringify, so the document does not know its JSON; say what it looks like: pub const openapi: zefir.openapi.Doc(Money) = .{ .as = []const u8 }" },
    .{ .file = dir ++ "operation_id_clash.zig", .expect = "zefir.openapi: TodosController.list and UsersController.list have one operationId, list; give one of them another with .operation_id in the routes of its ControllerDoc" },
    .{ .file = dir ++ "tag_two_descriptions.zig", .expect = "zefir.openapi: the tag Todos has two descriptions, of TodosV1Controller and of TodosV2Controller; describe it in one of them" },
    .{ .file = dir ++ "scheme_unknown.zig", .expect = "zefir.openapi: TodosController.list: requireBearer requires the scheme bearer, which no middleware before it declares" },
    .{ .file = dir ++ "security_any_without_schemes.zig", .expect = "zefir.openapi: TodosController.list: requireUser requires any scheme declared before it, but no middleware before it declares one; declare them in the .security_schemes of a middleware before it" },
    .{ .file = dir ++ "scheme_twice.zig", .expect = "zefir.openapi: two security schemes named bearer, of TokenAuth and of OtherAuth, are not the same; give one of them another name" },
    .{ .file = dir ++ "roles_without_security.zig", .expect = "zefir.openapi: TodosController.list: requirePermission(todos) adds the roles todos, but no middleware before it requires a scheme; put one with .security, such as .security = .any, before it" },
    .{ .file = dir ++ "include_and_exclude.zig", .expect = "zefir.openapi: .include and .exclude together; a document takes the controllers of .include, or all but those of .exclude" },
    .{ .file = dir ++ "include_unknown_controller.zig", .expect = "zefir.openapi: .exclude names HealthController, which is not a controller of the server; name the types of controllers of .controllers" },
    .{ .file = dir ++ "media_type_two_schemas.zig", .expect = "zefir.openapi: ItemsController.list: the response 429 has two schemas of application/json, of the middleware Limiter and of its errors, as AppErrors.mapError answers them; one media type of a status has one schema" },
    .{ .file = dir ++ "parameter_twice.zig", .expect = "zefir.openapi: ItemsController.list: two parameters limit in the query, of .query = ListQuery and of the middleware Paging (.query = PageQuery); give one of them another name" },
    .{ .file = dir ++ "unknown_fields_runtime.zig", .expect = "zefir.openapi: Server.init .unknown_fields comes at run time, but the document needs it at compile time: whether a body may hold keys its DTO does not know decides its schema; write it as a literal, such as .unknown_fields = .{ .body = .ignore }" },
    .{ .file = dir ++ "example_breaks_rules.zig", .expect = "zefir.openapi: CreateTodoRequest.openapi.example: title must be at most 20 characters (validation.max_length); give an example that passes the rules of CreateTodoRequest" },
    .{ .file = dir ++ "example_name_twice.zig", .expect = "zefir.openapi: CreateTodoRequest.openapi.examples has two examples named minimal; a request or a response shows them by their names" },
    .{ .file = dir ++ "license_identifier_and_url.zig", .expect = "zefir.openapi: .info.license has both .identifier and .url; OpenAPI takes one of them: the SPDX identifier, or the URL of the license" },
    .{ .file = dir ++ "oauth2_flow_url.zig", .expect = "zefir.openapi: the OAuth2 flow oauth.clientCredentials needs its .token_url" },
    .{ .file = dir ++ "scheme_name_invalid.zig", .expect = "zefir.openapi: the security scheme \"bearer token\" of TokenAuth is not a name of the document: 1 or more of A-Z, a-z, 0-9, '.', '-' and '_'" },
    .{ .file = dir ++ "route_anyerror.zig", .expect = "zefir.openapi: TodosController.list returns anyerror; the document needs the errors it can return: give it an error set" },
    // The paths of the controller of documentation.
    .{ .file = dir ++ "docs_path_relative.zig", .expect = "zefir.openapi: Docs: .json is \"openapi.json\", which does not start with '/'; write the path of the route within the server's prefix, such as .json = \"/openapi.json\"" },
};

const dir = "src/openapi/tests/compile_errors/";
