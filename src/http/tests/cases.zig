//! What build.zig compiles for the compile checks of zefir-http, read by
//! `addHttpCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is client
//! code: a `test` block that imports "http" (and "validator") and calls the
//! API under check.

/// A file that must fail to compile with an error whose message is
/// `expect`. With `whole`, `expect` is the whole text after `error: ` to
/// the end of the line; without it, only the end of the line, for messages
/// that start with a name that depends on the file.
pub const Fixture = struct { file: []const u8, expect: []const u8, whole: bool = true };

const handler_form = "pub fn get(self: *UsersV1Controller, ctx: *http.Context) !http.Json(T), or !void for a response without a JSON value";
const no_routes = "zefir.http: UsersV1Controller has no pub const http_routes = http.routes(.{ ... })";

/// Files in src/http/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // Controllers and their routes.
    .{ .file = dir ++ "controller_no_routes.zig", .expect = no_routes },
    .{ .file = dir ++ "controller_routes_not_pub.zig", .expect = no_routes },
    .{ .file = dir ++ "controller_routes_not_built.zig", .expect = "zefir.http: UsersV1Controller.http_routes must be http.routes(.{ ... })" },
    .{ .file = dir ++ "controller_by_value.zig", .expect = "zefir.http: Server.init .controllers[0] is UsersV1Controller; pass a pointer to the controller, e.g. &controller" },
    .{ .file = dir ++ "controller_const_pointer.zig", .expect = "zefir.http: Server.init .controllers[0] is *const UsersV1Controller; the controller must be mutable, declared with var" },
    .{ .file = dir ++ "controllers_empty.zig", .expect = "zefir.http: Server.init .controllers is a tuple of pointers to controllers, at least one: .{ &todos_v1, &health }" },
    // Handlers.
    .{ .file = dir ++ "handler_missing.zig", .expect = "zefir.http: UsersV1Controller.get: the route has no handler; write " ++ handler_form },
    .{ .file = dir ++ "handler_signature.zig", .expect = "; write " ++ handler_form, .whole = false },
    .{ .file = dir ++ "sse_handler_signature.zig", .expect = "; write pub fn events(self: *UsersV1Controller, ctx: *http.sse.Context) !void", .whole = false },
    .{ .file = dir ++ "sse_on_close_missing.zig", .expect = "zefir.http: UsersV1Controller.events: .on_close = .closed names no pub fn closed(self: *UsersV1Controller, ctx: *http.sse.Context) void" },
    .{ .file = dir ++ "sse_on_close_signature.zig", .expect = "zefir.http: UsersV1Controller.events: .on_close = .closed is fn (*UsersV1Controller, *http.sse.Context) !void; write pub fn closed(self: *UsersV1Controller, ctx: *http.sse.Context) void" },
    // Patterns.
    .{ .file = dir ++ "route_conflict.zig", .expect = "zefir.http: UsersV1Controller.get (GET /v1/users/{id}) and UsersV1Controller.byName (GET /v1/users/{name}) match the same requests" },
    .{ .file = dir ++ "route_unclosed_param.zig", .expect = "zefir.http: UsersV1Controller.get: route path \"/v1/users/{id\" has an unclosed {" },
    .{ .file = dir ++ "route_catch_all_not_last.zig", .expect = "zefir.http: UsersV1Controller.files: {*rest} must be the last segment of \"/v1/files/{*rest}/meta\"" },
    .{ .file = dir ++ "route_param_twice.zig", .expect = "zefir.http: UsersV1Controller.get: route path \"/v1/users/{id}/{id}\" names {id} twice" },
    .{ .file = dir ++ "route_bad_param_name.zig", .expect = "zefir.http: UsersV1Controller.get: {user id} is not a parameter name: 1 to 64 characters from A-Z, a-z, 0-9, '_' and '-'" },
    .{ .file = dir ++ "route_bad_path.zig", .expect = "zefir.http: a route path starts with '/' or is empty: \"users\"" },
    .{ .file = dir ++ "route_empty_segment.zig", .expect = "zefir.http: UsersV1Controller.get: route path \"/v1/users//{id}\" has an empty segment" },
    .{ .file = dir ++ "route_param_in_segment.zig", .expect = "zefir.http: UsersV1Controller.get: route path \"/v1/users/{id}.json\": a parameter is a whole segment, such as /{id}" },
    .{ .file = dir ++ "route_dot_segment.zig", .expect = "zefir.http: UsersV1Controller.get: route path \"/v1/users/../admin\" has a dot segment, which a request path never keeps" },
    .{ .file = dir ++ "controller_bad_prefix.zig", .expect = "zefir.http: a controller prefix starts with '/' or is empty: \"v1/users\"" },
    // Options.
    .{ .file = dir ++ "route_unknown_option.zig", .expect = "zefir.http: http.get(\"/x\"): unknown option .timout; the options are .middleware, .max_body_bytes and .timeout" },
    .{ .file = dir ++ "sse_unknown_option.zig", .expect = "zefir.http: http.sse.get(\"/events\"): unknown option .timeout; the options are .middleware, .heartbeat and .on_close" },
    .{ .file = dir ++ "routes_unknown_option.zig", .expect = "zefir.http: http.routes: unknown option .prefx; the options are .prefix, .middleware and .methods" },
    .{ .file = dir ++ "methods_not_route.zig", .expect = "zefir.http: http.routes: .methods.get must be a route, such as http.get(\"/{id}\", .{})" },
    .{ .file = dir ++ "server_unknown_option.zig", .expect = "zefir.http: Server.init: unknown option .contollers" },
    .{ .file = dir ++ "server_unknown_nested_option.zig", .expect = "zefir.http: Server.init: UnknownFieldsOptions has no option .bdy" },
    .{ .file = dir ++ "server_trusted_proxies.zig", .expect = "zefir.http: Server.init: .trusted_proxies is .all, .private, .none or .{ .list = &.{\"10.1.0.0/16\"} }" },
    // DTOs of the input.
    .{ .file = dir ++ "header_dto_rename.zig", .expect = "zefir.http: header_dto_rename.Headers.field_rules.request_id: v.rename does not apply to headers; field request_id reads the header Request-Id" },
    .{ .file = dir ++ "query_nested_struct.zig", .expect = "zefir.http: query_nested_struct.Query.filter: a struct field comes only from JSON; query, form, path, headers and cookies hold strings" },
    .{ .file = dir ++ "dto_not_struct.zig", .expect = "zefir.http: ctx.query takes a struct, got u32" },
    .{ .file = dir ++ "dto_bad_rule.zig", .expect = "validator: dto_bad_rule.IdPath.field_rules.id: max_length expects a string, field is u64" },
};

const dir = "src/http/tests/compile_errors/";

/// Files in src/http/tests/compile_ok/ that must compile.
pub const must_compile = [_][]const u8{
    "src/http/tests/compile_ok/routes.zig",
};
