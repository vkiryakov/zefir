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
    .{ .file = dir ++ "route_bad_literal.zig", .expect = "zefir.http: UsersV1Controller.search: route path \"/v1/users/search?q\": a segment is visible ASCII without '%', '?' and '#', written as the path reads decoded" },
    .{ .file = dir ++ "controller_bad_prefix.zig", .expect = "zefir.http: a controller prefix starts with '/' or is empty: \"v1/users\"" },
    // Options.
    .{ .file = dir ++ "route_unknown_option.zig", .expect = "zefir.http: http.get(\"/x\"): unknown option .timout; the options are .middleware, .max_body_bytes and .timeout" },
    .{ .file = dir ++ "sse_unknown_option.zig", .expect = "zefir.http: http.sse.get(\"/events\"): unknown option .timeout; the options are .middleware, .heartbeat and .on_close" },
    .{ .file = dir ++ "routes_unknown_option.zig", .expect = "zefir.http: http.routes: unknown option .prefx; the options are .prefix, .middleware and .methods" },
    .{ .file = dir ++ "route_negative_timeout.zig", .expect = "zefir.http: http.get(\"/export.csv\"): .timeout is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(300), or null for no deadline" },
    .{ .file = dir ++ "sse_zero_heartbeat.zig", .expect = "zefir.http: http.sse.get(\"/events\"): .heartbeat is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(15), or null for none" },
    .{ .file = dir ++ "methods_not_route.zig", .expect = "zefir.http: http.routes: .methods.get must be a route, such as http.get(\"/{id}\", .{})" },
    .{ .file = dir ++ "server_unknown_option.zig", .expect = "zefir.http: Server.init: unknown option .contollers" },
    .{ .file = dir ++ "server_unknown_nested_option.zig", .expect = "zefir.http: Server.init: UnknownFieldsOptions has no option .bdy" },
    .{ .file = dir ++ "server_trusted_proxies.zig", .expect = "zefir.http: Server.init: .trusted_proxies is .all, .private, .none or .{ .list = &.{\"10.1.0.0/16\"} }" },
    // DTOs of the input.
    .{ .file = dir ++ "header_dto_rename.zig", .expect = "zefir.http: header_dto_rename.Headers.field_rules.request_id: v.rename does not apply to headers; field request_id reads the header Request-Id" },
    .{ .file = dir ++ "query_nested_struct.zig", .expect = "zefir.http: query_nested_struct.Query.filter: a struct field comes only from JSON; query, form, path, headers and cookies hold strings" },
    .{ .file = dir ++ "dto_not_struct.zig", .expect = "zefir.http: ctx.query takes a struct, got u32" },
    .{ .file = dir ++ "dto_bad_rule.zig", .expect = "validator: dto_bad_rule.IdPath.field_rules.id: max_length expects a string, field is u64" },
    .{ .file = dir ++ "json_unsupported_field.zig", .expect = "zefir.http: json_unsupported_field.Item.codes: [3]u8 does not come from JSON; ctx.json reads integers, floats, bool, enums, []const u8 and structs, alone, as ?T or as []const T" },
    // The strict error check.
    .{ .file = dir ++ "strict_app_error.zig", .expect = "UsersV1Controller.create can return error.UserLimitReached; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_default_handler.zig", .expect = "UsersV1Controller.create can return error.UserLimitReached; the default error handler gives it 500; set .error_handler and map it" ++ strict_hint },
    .{ .file = dir ++ "strict_framework_error.zig", .expect = "AppErrors.mapError gives error.RouteNotFound 500, while its status is 404; map it or keep .fallback in else" ++ strict_hint },
    .{ .file = dir ++ "strict_anyerror_handler.zig", .expect = "zefir.http: UsersV1Controller.get returns anyerror; the strict error check needs the errors it can return: give it an error set" ++ strict_hint },
    .{ .file = dir ++ "strict_input_transform_error.zig", .expect = "UsersV1Controller.search can return error.TooManyTags; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_response_transform_error.zig", .expect = "UsersV1Controller.get (writing its response) can return error.BadDisplayName; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_errors_runtime.zig", .expect = "zefir.http: Server.init .strict_errors must be known at compile time: true or false" },
    // The error handler.
    .{ .file = dir ++ "error_handler_no_map.zig", .expect = "zefir.http: the error handler AppErrors has no pub fn mapError(err: anyerror) http.ErrorResponse(Body)" },
    .{ .file = dir ++ "error_handler_handle_signature.zig", .expect = "; write pub fn handle(self: *AppErrors, ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(ApiError)) !http.ErrorAction", .whole = false },
    .{ .file = dir ++ "error_handler_map_signature.zig", .expect = "; write pub fn mapError(err: anyerror) http.ErrorResponse(Body) (no ctx: the strict error check calls it at compile time)", .whole = false },
    .{ .file = dir ++ "error_handler_by_value.zig", .expect = "zefir.http: Server.init .error_handler is AppErrors; pass a pointer to the error handler, e.g. &app_errors" },
    // Middleware.
    .{ .file = dir ++ "mw_pointer_in_controller.zig", .expect = "zefir.http: UsersV1Controller.http_routes.middleware[0]: a pointer to an object goes into the server's middleware; in a controller, make it a field and name it: .field" },
    .{ .file = dir ++ "mw_unknown_element.zig", .expect = "zefir.http: Server.init .middleware[1]: an element of type 'comptime_int' is not middleware; write a function fn (ctx: *http.Context) !http.MiddlewareResult, " ++
        "a type with pub fn run, a pointer to an object with run, onResponse or onFinish, http.onResponse(f), http.onFinish(f), a tuple of them, or in a controller .field" },
    .{ .file = dir ++ "mw_object_no_phase.zig", .expect = "zefir.http: Server.init .middleware[0]: mw_object_no_phase.Empty has none of pub fn run(self: *@This(), ctx: *http.Context) !http.MiddlewareResult, " ++
        "pub fn onResponse(self: *@This(), ctx: *http.Context) !void, pub fn onFinish(self: *@This(), ctx: *http.Context, outcome: http.Outcome) !void" },
    .{ .file = dir ++ "mw_field_missing.zig", .expect = "zefir.http: UsersV1Controller.http_routes.methods.delete.middleware[1]: .audt is not a field of UsersV1Controller" },
    .{ .file = dir ++ "mw_field_not_pointer.zig", .expect = "zefir.http: UsersV1Controller.http_routes.methods.delete.middleware[1]: field 'audit' of UsersV1Controller is 'mw_field_not_pointer.Audit'; it must point to a middleware object" },
    .{ .file = dir ++ "mw_run_anyerror.zig", .expect = "zefir.http: requireUser.run (middleware of UsersV1Controller.get) returns anyerror; the strict error check needs the errors it can return: give it an error set" ++ strict_hint },
    .{ .file = dir ++ "strict_middleware_error.zig", .expect = "requirePermission(users:delete).run (middleware of UsersV1Controller.delete) can return error.NoSuchTenant; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "mw_phase_signature.zig", .expect = "zefir.http: Server.init .middleware[0]: Timing.run is fn (*http.Context) !http.MiddlewareResult; write pub fn run(self: *@This(), ctx: *http.Context) !http.MiddlewareResult" },
};

const strict_hint = " (strict error check; .strict_errors = false turns it off)";

const dir = "src/http/tests/compile_errors/";

/// Files in src/http/tests/compile_ok/ that must compile.
pub const must_compile = [_][]const u8{
    "src/http/tests/compile_ok/routes.zig",
    "src/http/tests/compile_ok/strict_off.zig",
};
