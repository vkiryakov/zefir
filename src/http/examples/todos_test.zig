//! Tests of the example app without a network: `http.testing.Backend`
//! serves the same server, the same controllers and the same middleware
//! from memory, as `Service.start` builds them for `main`. The settings are
//! read with confy from an environment of the test's own, and the access
//! log is written where the test can read it. The tests reach every route,
//! and in a Debug build the server checks each request and each response
//! against what its route declares; the last test compares the OpenAPI
//! document with openapi.json.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const log = @import("log");
const zefir = @import("zefir");
const auth = @import("auth.zig");
const Service = @import("Service.zig");
/// Where the files of the app are, as the build gives them: the directory
/// of the page and openapi.json.
const paths = @import("paths");

const testing = std.testing;

/// The settings of the app that the tests need: the tokens of its users.
const Config = struct {
    auth: struct {
        ann_token: confy.Secret,
        bob_token: confy.Secret,
    },
};

/// The app as `main` builds it, on the backend in memory.
const App = struct {
    arena: std.heap.ArenaAllocator,
    config: Config = undefined,
    /// What the access log wrote, a record per line.
    records: std.Io.Writer.Allocating,
    logger: log.Logger = undefined,
    users: [2]auth.TokenAuth.User = undefined,
    origins: [1][]const u8 = .{"http://localhost:5173"},
    backend: http.testing.Backend,
    service: Service = undefined,

    /// Starts the app; `app` stays where it is until `stop`.
    fn start(app: *App) !void {
        const gpa = testing.allocator;
        app.* = .{
            .arena = .init(gpa),
            .records = .init(gpa),
            .backend = .init(gpa),
        };
        errdefer app.free();

        var environ: std.process.Environ.Map = .init(gpa);
        defer environ.deinit();
        try environ.put("APP_AUTH_ANN_TOKEN", "ann-secret");
        try environ.put("APP_AUTH_BOB_TOKEN", "bob-secret");
        try confy.load(app.arena.allocator(), &app.config, .{
            .io = testing.io,
            .environ = &environ,
            .env_prefix = "APP_",
            .sources = &.{.osEnv()},
        });
        app.logger = try .init(gpa, testing.io, .{ .format = .text, .output = .{ .writer = &app.records.writer } });
        errdefer app.logger.deinit();

        app.users = .{
            .{ .token = app.config.auth.ann_token, .id = "ann", .permissions = &.{ "todos", "todos:delete" } },
            .{ .token = app.config.auth.bob_token, .id = "bob", .permissions = &.{"todos"} },
        };
        app.service = .{ .users = &app.users, .origins = &app.origins, .public_dir = paths.public_dir, .logger = app.logger };
        try app.service.start(gpa, testing.io, app.backend.backend());
    }

    /// Stops the service first: what it borrowed goes after it.
    fn stop(app: *App) void {
        app.service.deinit(testing.allocator, testing.io);
        app.logger.deinit();
        app.free();
    }

    fn free(app: *App) void {
        app.backend.deinit();
        app.records.deinit();
        app.arena.deinit();
    }

    fn request(app: *App, method: std.http.Method, target: []const u8, headers: []const [2][]const u8, body: []const u8) !http.testing.Response {
        return app.backend.request(testing.io, .{ .method = method, .target = target, .headers = headers, .body = body });
    }

    /// A request of Ann's, with a JSON body when there is one.
    fn asAnn(app: *App, method: std.http.Method, target: []const u8, body: []const u8) !http.testing.Response {
        const json: []const [2][]const u8 = &.{ .{ "authorization", "Bearer ann-secret" }, .{ "content-type", "application/json" } };
        return app.request(method, target, if (body.len > 0) json else json[0..1], body);
    }
};

/// The body of an error response.
const ApiError = struct {
    code: []const u8,
    details: []const struct { field: []const u8, code: []const u8 } = &.{},
};

fn errorOf(res: *http.testing.Response) !ApiError {
    return std.json.parseFromSliceLeaky(ApiError, res.arena.allocator(), res.body, .{ .ignore_unknown_fields = true });
}

test "a todo is made, read, changed and deleted, and the other user never sees it" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    var created = try app.asAnn(.POST, "/api/v1/todos", "{\"title\":\"  Buy milk  \",\"dueDate\":\"2026-10-20\",\"tags\":[\" Shop \"]}");
    defer created.deinit();
    try testing.expectEqual(201, created.status);
    // Trimmed by the transforms of field_rules, written by its outside names.
    try testing.expectEqualStrings("{\"id\":1,\"title\":\"Buy milk\",\"done\":false,\"priority\":\"normal\",\"dueDate\":\"2026-10-20\",\"tags\":[\"shop\"]}", created.body);

    var changed = try app.asAnn(.PATCH, "/api/v1/todos/1", "{\"done\":true}");
    defer changed.deinit();
    try testing.expectEqualStrings("{\"id\":1,\"title\":\"Buy milk\",\"done\":true,\"priority\":\"normal\",\"dueDate\":\"2026-10-20\",\"tags\":[\"shop\"]}", changed.body);

    var found = try app.asAnn(.GET, "/api/v1/todos?done=true&tags=shop&q=MILK", "");
    defer found.deinit();
    try testing.expectEqualStrings("{\"items\":[{\"id\":1,\"title\":\"Buy milk\",\"done\":true,\"priority\":\"normal\",\"dueDate\":\"2026-10-20\",\"tags\":[\"shop\"]}],\"page\":1,\"perPage\":20,\"total\":1}", found.body);

    // Bob has none, and Ann's is no todo of his.
    var bobs = try app.request(.GET, "/api/v1/todos", &.{.{ "authorization", "Bearer bob-secret" }}, "");
    defer bobs.deinit();
    try testing.expectEqualStrings("{\"items\":[],\"page\":1,\"perPage\":20,\"total\":0}", bobs.body);
    var not_his = try app.request(.GET, "/api/v1/todos/1", &.{.{ "authorization", "Bearer bob-secret" }}, "");
    defer not_his.deinit();
    try testing.expectEqual(404, not_his.status);
    try testing.expectEqualStrings("todos.not_found", (try errorOf(&not_his)).code);

    var deleted = try app.asAnn(.DELETE, "/api/v1/todos/1", "");
    defer deleted.deinit();
    try testing.expectEqual(204, deleted.status);
    var gone = try app.asAnn(.GET, "/api/v1/todos/1", "");
    defer gone.deinit();
    try testing.expectEqual(404, gone.status);
}

test "a body that does not fit is a 422 in the API's format, with every field at once" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    var res = try app.asAnn(.POST, "/api/v1/todos", "{\"titel\":\"Buy milk\",\"priority\":\"urgent\"}");
    defer res.deinit();
    try testing.expectEqual(422, res.status);
    try testing.expectEqualStrings("application/json", res.header("content-type") orelse return error.TestUnexpectedResult);
    const body = try errorOf(&res);
    try testing.expectEqualStrings("validation_failed", body.code);
    try testing.expectEqual(3, body.details.len);
    try testing.expectEqualStrings("titel", body.details[0].field);
    try testing.expectEqualStrings("http.unknown_field", body.details[0].code);
    try testing.expectEqualStrings("priority", body.details[1].field);
    try testing.expectEqualStrings("http.invalid_type", body.details[1].code);
    try testing.expectEqualStrings("title", body.details[2].field);
    try testing.expectEqualStrings("http.missing_field", body.details[2].code);

    // The rules see the trimmed value; the query has its own names.
    var blank = try app.asAnn(.POST, "/api/v1/todos", "{\"title\":\"   \",\"dueDate\":\"2026-13-01\"}");
    defer blank.deinit();
    const rules = try errorOf(&blank);
    try testing.expectEqual(2, rules.details.len);
    try testing.expectEqualStrings("validation.not_blank", rules.details[0].code);
    try testing.expectEqualStrings("dueDate", rules.details[1].field);
    var page = try app.asAnn(.GET, "/api/v1/todos?perPage=500", "");
    defer page.deinit();
    const query = try errorOf(&page);
    try testing.expectEqual(1, query.details.len);
    try testing.expectEqualStrings("perPage", query.details[0].field);
}

test "the free plan allows three todos, the fourth is a 409; the same Idempotency-Key gives the first todo back" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    const headers: []const [2][]const u8 = &.{
        .{ "authorization", "Bearer ann-secret" },
        .{ "content-type", "application/json" },
        .{ "idempotency-key", "groceries-1" },
    };
    var first = try app.request(.POST, "/api/v1/todos", headers, "{\"title\":\"Buy milk\"}");
    defer first.deinit();
    try testing.expectEqual(201, first.status);
    // A retry: the todo of the first request, not a second one.
    var again = try app.request(.POST, "/api/v1/todos", headers, "{\"title\":\"Buy milk\"}");
    defer again.deinit();
    try testing.expectEqual(200, again.status);
    try testing.expectEqualStrings(first.body, again.body);

    for ([_][]const u8{ "{\"title\":\"Call Bob\"}", "{\"title\":\"Water the plants\"}" }) |body| {
        var res = try app.asAnn(.POST, "/api/v1/todos", body);
        defer res.deinit();
        try testing.expectEqual(201, res.status);
    }
    var over = try app.asAnn(.POST, "/api/v1/todos", "{\"title\":\"One more\"}");
    defer over.deinit();
    try testing.expectEqual(409, over.status);
    try testing.expectEqualStrings("todos.limit_reached", (try errorOf(&over)).code);
}

test "without a user: 401 with WWW-Authenticate; Bob may read but not delete: 403" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    var anonymous = try app.request(.GET, "/api/v1/todos", &.{}, "");
    defer anonymous.deinit();
    try testing.expectEqual(401, anonymous.status);
    try testing.expectEqualStrings("Bearer", anonymous.header("www-authenticate") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("unauthenticated", (try errorOf(&anonymous)).code);

    // The health check needs no user.
    var health = try app.request(.GET, "/api/health", &.{}, "");
    defer health.deinit();
    try testing.expectEqualStrings("{\"status\":\"ok\"}", health.body);

    var denied = try app.request(.DELETE, "/api/v1/todos/1", &.{.{ "authorization", "Bearer bob-secret" }}, "");
    defer denied.deinit();
    try testing.expectEqual(403, denied.status);
    try testing.expectEqualStrings("permission_denied", (try errorOf(&denied)).code);
}

test "the stream of live updates gets each todo as it is made" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    // The cookie, as a browser's EventSource sends it.
    var stream = try app.backend.open(testing.io, .{
        .method = .GET,
        .target = "/api/v1/todos/events",
        .headers = &.{.{ "cookie", "session=ann-secret" }},
    });
    defer stream.deinit(testing.io);
    try testing.expectEqual(200, stream.status);
    try testing.expectEqualStrings("text/event-stream", stream.header("content-type") orelse return error.TestUnexpectedResult);

    var created = try app.asAnn(.POST, "/api/v1/todos", "{\"title\":\"Buy milk\"}");
    defer created.deinit();
    const event = try stream.next(testing.io, .fromSeconds(5)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("event: todo.created\ndata: {\"id\":1,\"title\":\"Buy milk\",\"done\":false,\"priority\":\"normal\",\"dueDate\":null,\"tags\":[]}\n\n", event);
}

test "the export is a CSV attachment, its quotes doubled" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    var created = try app.asAnn(.POST, "/api/v1/todos", "{\"title\":\"Read \\\"Dune\\\"\"}");
    defer created.deinit();
    var res = try app.asAnn(.GET, "/api/v1/todos/export.csv", "");
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("text/csv", res.header("content-type") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("id,title,done\n1,\"Read \"\"Dune\"\"\",false\n", res.body);
    const disposition = res.header("content-disposition") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, disposition, "attachment; filename=\"todos.csv\""));
}

test "a form signs a browser in with the cookie session and a 303, a form of another site gets 403; signing out clears it" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    const form: [2][]const u8 = .{ "content-type", "application/x-www-form-urlencoded" };
    // The browser says that the page of this site sent it.
    var login = try app.request(.POST, "/api/session", &.{ form, .{ "sec-fetch-site", "same-origin" } }, "token=ann-secret");
    defer login.deinit();
    try testing.expectEqual(303, login.status);
    try testing.expectEqualStrings("/", login.header("location") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("session=ann-secret; Path=/; Max-Age=28800; Secure; HttpOnly; SameSite=Lax", login.header("set-cookie") orelse return error.TestUnexpectedResult);

    var wrong = try app.request(.POST, "/api/session", &.{form}, "token=guess");
    defer wrong.deinit();
    try testing.expectEqual(401, wrong.status);

    // The page of another site, as a browser says, or as the Origin of an
    // older one shows: 403, and no cookie.
    for ([_][2][]const u8{ .{ "sec-fetch-site", "cross-site" }, .{ "origin", "https://evil.example" } }) |from| {
        var forged = try app.request(.POST, "/api/session", &.{ form, from, .{ "host", "localhost:8080" } }, "token=ann-secret");
        defer forged.deinit();
        try testing.expectEqual(403, forged.status);
        try testing.expectEqual(null, forged.header("set-cookie"));
    }

    var logout = try app.request(.DELETE, "/api/session", &.{.{ "cookie", "session=ann-secret" }}, "");
    defer logout.deinit();
    try testing.expectEqual(204, logout.status);
    try testing.expectEqualStrings("session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax", logout.header("set-cookie") orelse return error.TestUnexpectedResult);
}

test "the access log writes a record for every request, the refused ones too" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    // The id of each request comes from its client, a trusted proxy here.
    for ([_][]const u8{ "/api/health", "/api/v1/todos" }) |target| {
        var res = try app.request(.GET, target, &.{.{ "x-request-id", "test-1" }}, "");
        res.deinit();
    }
    // `request` returns once the request has ended, its onFinish phases too.
    var lines = std.mem.splitScalar(u8, app.records.written(), '\n');
    const first = lines.next() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, first, "[access] Request method=GET path=/api/health status=200 user=- err=- request=test-1") != null);
    const second = lines.next() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, second, "[access] Request method=GET path=/api/v1/todos status=401 user=- err=Unauthenticated request=test-1") != null);
}

test "the OpenAPI document is openapi.json, which the service serves with a page of it" {
    var app: App = undefined;
    try app.start();
    defer app.stop();

    // With ZEFIR_OPENAPI_UPDATE=1 in the environment, `zig build openapi`
    // writes the file instead.
    try zefir.openapi.testing.expectFile(testing.io, app.service.docs.document, paths.openapi_json);

    var document = try app.request(.GET, "/api/openapi.json", &.{}, "");
    defer document.deinit();
    try testing.expectEqual(200, document.status);
    try testing.expectEqualStrings("application/json", document.header("content-type") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("no-cache", document.header("cache-control") orelse return error.TestUnexpectedResult);
    // A client that has it already gets 304, without a body.
    const etag = document.header("etag") orelse return error.TestUnexpectedResult;
    var again = try app.request(.GET, "/api/openapi.json", &.{.{ "if-none-match", etag }}, "");
    defer again.deinit();
    try testing.expectEqual(304, again.status);
    var page = try app.request(.GET, "/api/docs", &.{}, "");
    defer page.deinit();
    try testing.expectEqual(200, page.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", page.header("content-type") orelse return error.TestUnexpectedResult);
}
