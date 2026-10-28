//! What build.zig compiles for the compile checks of zefir-http, read by
//! `addHttpCompileChecks`. Paths are relative to the repository root and
//! stay inside `src/`, the part of the package that `build.zig.zon` ships,
//! since a client's build runs zefir's build.zig too. Each file is client
//! code: a `test` block that imports "http" (and "validator") and calls the
//! API under check.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
/// `debug`: an error of the Debug check (check.zig), which reads the
/// declarations in Debug builds only, so the file is compiled only when
/// -Doptimize is Debug.
pub const Fixture = struct { file: []const u8, expect: []const u8, debug: bool = false };

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
    .{ .file = dir ++ "handler_signature.zig", .expect = "zefir.http: UsersV1Controller.get is fn (*UsersV1Controller, *const http.Context) !void; write " ++ handler_form },
    .{ .file = dir ++ "sse_handler_signature.zig", .expect = "zefir.http: UsersV1Controller.events is fn (*UsersV1Controller, *http.Context) !void; write pub fn events(self: *UsersV1Controller, ctx: *http.sse.Context) !void" },
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
    .{ .file = dir ++ "route_unknown_option.zig", .expect = "zefir.http: http.get(\"/x\"): unknown option .timout; the options are .path, .query, .body, .form, .headers, .cookies, .responses, .middleware, .max_body_bytes and .timeout" },
    .{ .file = dir ++ "sse_unknown_option.zig", .expect = "zefir.http: http.sse.get(\"/events\"): unknown option .timeout; the options are .path, .query, .headers, .cookies, .events, .middleware, .heartbeat and .on_close" },
    .{ .file = dir ++ "routes_unknown_option.zig", .expect = "zefir.http: http.routes: unknown option .prefx; the options are .prefix, .middleware and .methods" },
    .{ .file = dir ++ "route_negative_timeout.zig", .expect = "zefir.http: http.get(\"/export.csv\"): .timeout is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(300), or null for no deadline" },
    .{ .file = dir ++ "sse_zero_heartbeat.zig", .expect = "zefir.http: http.sse.get(\"/events\"): .heartbeat is a std.Io.Duration above zero, such as std.Io.Duration.fromSeconds(15), or null for none" },
    .{ .file = dir ++ "methods_not_route.zig", .expect = "zefir.http: http.routes: .methods.get must be a route, such as http.get(\"/{id}\", .{})" },
    // The declarations of a route: its input and its statuses.
    .{ .file = dir ++ "route_input_not_type.zig", .expect = "zefir.http: http.get(\"/{id}\"): .path is the type of a DTO, such as .path = dto.TodoIdPath" },
    .{ .file = dir ++ "route_declared_dto.zig", .expect = "zefir.http: route_declared_dto.Query.filter: a struct field comes only from JSON; query, form, path, headers and cookies hold strings" },
    .{ .file = dir ++ "route_declared_headers.zig", .expect = "zefir.http: route_declared_headers.Headers.field_rules.request_id: v.rename does not apply to headers; field request_id reads the header Request-Id" },
    .{ .file = dir ++ "route_declared_body.zig", .expect = "zefir.http: route_declared_body.CreateRequest.codes: [3]u8 does not come from JSON; ctx.json reads integers, floats, bool, enums, []const u8 and structs, alone, as ?T or as []const T" },
    .{ .file = dir ++ "route_body_and_form.zig", .expect = "zefir.http: http.post(\"\"): .body and .form together; a body is JSON or a form" },
    .{ .file = dir ++ "sse_route_body.zig", .expect = "zefir.http: http.sse.get(\"/events\"): unknown option .body; the options are .path, .query, .headers, .cookies, .events, .middleware, .heartbeat and .on_close" },
    .{ .file = dir ++ "route_path_param_without_field.zig", .expect = "zefir.http: UsersV1Controller.get: {id} in \"/v1/users/{id}\" has no field in .path = UserPath" },
    .{ .file = dir ++ "route_path_field_without_param.zig", .expect = "zefir.http: UsersV1Controller.list: .path = UserPath has the field id, but \"/v1/users\" has no {id}" },
    .{ .file = dir ++ "route_catch_all_field.zig", .expect = "zefir.http: UsersV1Controller.files: {*path} in \"/v1/files/{*path}\", the rest of the path, goes to the field path of .path = FilePath, a u32; make it a []const u8 or a ?[]const u8" },
    .{ .file = dir ++ "route_responses_not_struct.zig", .expect = "zefir.http: http.post(\"\"): .responses is a struct literal of statuses, such as .responses = .{ .created = .{}, .ok = .{} }" },
    .{ .file = dir ++ "route_responses_status.zig", .expect = "zefir.http: http.post(\"\"): .responses.okay: the keys of .responses are names of std.http.Status, such as .ok, .created or .see_other" },
    .{ .file = dir ++ "route_responses_entry.zig", .expect = "zefir.http: http.post(\"\"): .responses.created must be .{}, .{ .content_type = \"text/csv\" } or .{ .json = T }" },
    .{ .file = dir ++ "route_responses_json_route.zig", .expect = "zefir.http: UsersV1Controller.create: .responses.created has a body of its own, but the handler returns http.Json(UserResponse), whose value is the body of its 2xx responses; write .created = .{}" },
    .{ .file = dir ++ "route_responses_no_body.zig", .expect = "zefir.http: http.put(\"/sync\"): .responses.no_content declares a body, but a 204 response has none; write .no_content = .{}" },
    .{ .file = dir ++ "input_not_route.zig", .expect = "zefir.http: ctx.input takes a route, such as ctx.input(Get) with const Get = http.get(\"/{id}\", .{ .path = dto.TodoIdPath }); got u32" },
    .{ .file = dir ++ "sse_input_rest_route.zig", .expect = "zefir.http: ctx.input of an http.sse.Context takes the route of its stream, made by http.sse.get; got http.post(\"/import\")" },
    // The events of a stream and its manager.
    .{ .file = dir ++ "sse_events_missing.zig", .expect = "zefir.http: http.sse.get(\"/events\") needs .events, a union(enum) of the stream's events, such as .events = dto.LiveEvent" },
    .{ .file = dir ++ "sse_events_not_union.zig", .expect = "zefir.http: http.sse.get(\"/events\"): .events is a union(enum) of the stream's events, such as .events = dto.LiveEvent; got u32" },
    .{ .file = dir ++ "sse_manager_not_union.zig", .expect = "zefir.http: http.sse.Manager takes a union(enum) of the stream's events, such as http.sse.Manager(dto.LiveEvent); got u32" },
    .{ .file = dir ++ "sse_event_name_line.zig", .expect = "zefir.http: http.sse.Manager(LiveEvent): the event .@\"todo\\ncreated\" has CR, LF or NUL in its name, which would break its line" },
    // The compiler's own: the event is a value of the union.
    .{ .file = dir ++ "sse_publish_unknown_event.zig", .expect = "no field named 'todo.archived' in union 'sse_publish_unknown_event.LiveEvent'" },
    .{ .file = dir ++ "sse_publish_wrong_data.zig", .expect = "expected type 'sse_publish_wrong_data.Todo', found 'comptime_int'" },
    // The parts of Server.init, and its typed options, which Zig checks.
    .{ .file = dir ++ "server_unknown_option.zig", .expect = "zefir.http: Server.init: unknown part .contollers" ++ parts_list },
    .{ .file = dir ++ "parts_unknown.zig", .expect = "zefir.http: Server.init: unknown part .prefix" ++ parts_list },
    .{ .file = dir ++ "parts_not_struct.zig", .expect = "zefir.http: Server.init takes a struct literal of parts, got *parts_not_struct.UsersV1Controller" },
    .{ .file = dir ++ "options_no_listen.zig", .expect = "missing struct field: listen" },
    .{ .file = dir ++ "server_unknown_nested_option.zig", .expect = "no field named 'bdy' in struct 'Server.UnknownFieldsOptions'" },
    .{ .file = dir ++ "server_trusted_proxies.zig", .expect = "no field named 'lst' in union 'proxies.TrustedProxies'" },
    // DTOs of the input.
    .{ .file = dir ++ "header_dto_rename.zig", .expect = "zefir.http: header_dto_rename.Headers.field_rules.request_id: v.rename does not apply to headers; field request_id reads the header Request-Id" },
    .{ .file = dir ++ "query_nested_struct.zig", .expect = "zefir.http: query_nested_struct.Query.filter: a struct field comes only from JSON; query, form, path, headers and cookies hold strings" },
    .{ .file = dir ++ "dto_not_struct.zig", .expect = "zefir.http: ctx.query takes a struct, got u32" },
    .{ .file = dir ++ "dto_bad_rule.zig", .expect = "validator: dto_bad_rule.IdPath.field_rules.id: max_length expects a string, field is u64" },
    .{ .file = dir ++ "json_unsupported_field.zig", .expect = "zefir.http: json_unsupported_field.Item.codes: [3]u8 does not come from JSON; ctx.json reads integers, floats, bool, enums, []const u8 and structs, alone, as ?T or as []const T" },
    // The strict error check.
    .{ .file = dir ++ "strict_app_error.zig", .expect = "zefir.http: UsersV1Controller.create can return error.UserLimitReached; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_default_handler.zig", .expect = "zefir.http: UsersV1Controller.create can return error.UserLimitReached; the default error handler gives it 500; set .error_handler and map it" ++ strict_hint },
    .{ .file = dir ++ "strict_framework_error.zig", .expect = "zefir.http: AppErrors.mapError gives error.RouteNotFound 500, while its status is 404; map it or keep .fallback in else" ++ strict_hint },
    .{ .file = dir ++ "strict_anyerror_handler.zig", .expect = "zefir.http: UsersV1Controller.get returns anyerror; the strict error check needs the errors it can return: give it an error set" ++ strict_hint },
    .{ .file = dir ++ "strict_input_transform_error.zig", .expect = "zefir.http: UsersV1Controller.search can return error.TooManyTags; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_response_transform_error.zig", .expect = "zefir.http: UsersV1Controller.get (writing its response) can return error.BadDisplayName; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "strict_errors_runtime.zig", .expect = "zefir.http: Server.init .strict_errors must be known at compile time: true or false" },
    // The error handler.
    .{ .file = dir ++ "error_handler_no_map.zig", .expect = "zefir.http: the error handler AppErrors has no pub fn mapError(err: anyerror) http.ErrorResponse(Body)" },
    .{ .file = dir ++ "error_handler_handle_signature.zig", .expect = "zefir.http: AppErrors.handle is fn (*AppErrors, *const http.Context, anyerror, *http.ErrorResponse(ApiError)) !http.ErrorAction; write pub fn handle(self: *AppErrors, ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(ApiError)) !http.ErrorAction" },
    .{ .file = dir ++ "error_handler_map_signature.zig", .expect = "zefir.http: AppErrors.mapError is fn (*http.Context, anyerror) http.ErrorResponse(ApiError); write pub fn mapError(err: anyerror) http.ErrorResponse(Body) (no ctx: the strict error check calls it at compile time)" },
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
    .{ .file = dir ++ "strict_middleware_error.zig", .expect = "zefir.http: requirePermission(users:delete).run (middleware of UsersV1Controller.delete) can return error.NoSuchTenant; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
    .{ .file = dir ++ "mw_phase_signature.zig", .expect = "zefir.http: Server.init .middleware[0]: Timing.run is fn (*http.Context) !http.MiddlewareResult; write pub fn run(self: *@This(), ctx: *http.Context) !http.MiddlewareResult" },
    // The openapi of a middleware on a route of the document, as the Debug
    // check reads it.
    .{ .file = dir ++ "mw_openapi_not_struct.zig", .expect = "zefir.http: the openapi of the middleware Paging is a zefir.openapi.MiddlewareDoc, such as .{ .query = PageQuery }; got type", .debug = true },
    .{ .file = dir ++ "mw_openapi_input_not_type.zig", .expect = "zefir.http: the openapi of the middleware Paging: .query is the type of a DTO, such as .query = PageQuery, or void", .debug = true },
    .{ .file = dir ++ "mw_openapi_responses_not_struct.zig", .expect = "zefir.http: the openapi of the middleware Paging: .responses is a struct of statuses, such as .responses = .{ .not_modified = .{} }", .debug = true },
    .{ .file = dir ++ "mw_openapi_responses_status.zig", .expect = "zefir.http: the openapi of the middleware Paging: .responses names .notModified; its keys are names of std.http.Status, such as .not_modified", .debug = true },
    // A mistake that src/http/examples/README.md shows in its service, whose
    // message no other probe gives: the guide's check finds each error it
    // shows here.
    .{ .file = dir ++ "guide_strict_app_error.zig", .expect = "zefir.http: TodosV1Controller.create can return error.TodoLimitReached; AppErrors.mapError gives it 500 through .fallback" ++ strict_hint },
};

const strict_hint = " (strict error check; .strict_errors = false turns it off)";
const parts_list = "; the parts are .controllers, .middleware, .error_handler and .strict_errors";

const dir = "src/http/tests/compile_errors/";

/// Files in src/http/tests/compile_ok/ that must compile.
pub const must_compile = [_][]const u8{
    "src/http/tests/compile_ok/routes.zig",
    "src/http/tests/compile_ok/strict_off.zig",
};
