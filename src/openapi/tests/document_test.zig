//! The document of a server, part by part: its operations in the server's
//! order, parameters, bodies, the responses of the table of design §7, the
//! answers to errors of §8, security of §9, tags and operationIds, SSE in
//! 3.1 and 3.2, servers, what is left out, and the texts. The expected JSON
//! is written compact; the document writes the same values laid out.
const std = @import("std");
const http = @import("http");
const v = @import("validator");
const json = @import("../json.zig");
const openapi = @import("../openapi.zig");
const document = @import("../document.zig").document;

const Doc = openapi.Doc;
const ControllerDoc = openapi.ControllerDoc;
const MiddlewareDoc = openapi.MiddlewareDoc;
const testing = std.testing;

/// `node` as compact JSON.
fn compact(node: json.Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node) {
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(m.key, .{}, w);
                try w.writeByte(':');
                try compact(m.value, w);
            }
            try w.writeByte('}');
        },
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try compact(item, w);
            }
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .raw => |text| try w.writeAll(text),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
    }
}

fn expectJson(expected: []const u8, node: json.Node) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(node, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

/// The member at `path` of `node`, each step a key of an object.
fn at(comptime node: json.Node, comptime path: []const []const u8) json.Node {
    comptime {
        var here = node;
        for (path) |key| here = json.get(here.object, key) orelse @compileError("no member " ++ key);
        return here;
    }
}

/// The keys of an object, joined by spaces.
fn keysOf(comptime node: json.Node) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (node.object, 0..) |m, i| out = out ++ (if (i == 0) "" else " ") ++ m.key;
        return out;
    }
}

const info: openapi.DocumentOptions.Info = .{ .title = "Todos API", .version = "1.0.0" };

// Application code of the tests: zefir ships no DTO, controller or error
// handler.

/// The application of design §3.
const small = struct {
    const TodoIdPath = struct {
        id: u64,

        pub const field_rules = .{ .id = v.positive };

        pub const openapi: Doc(@This()) = .{
            .fields = .{ .id = .{ .description = "The id of the todo.", .example = 1 } },
        };
    };

    const TodoResponse = struct {
        id: u64,
        title: []const u8,
        done: bool,

        pub const openapi: Doc(@This()) = .{
            .description = "A todo, as the API shows it.",
            .fields = .{
                .id = .{ .description = "The id of the todo." },
                .title = .{ .description = "What to do." },
                .done = .{ .description = "Whether it is done." },
            },
        };
    };

    const TodosController = struct {
        const Get = http.get("/{id}", .{ .path = TodoIdPath });

        pub const http_routes = http.routes(.{
            .prefix = "/v1/todos",
            .methods = .{ .get = Get },
        });

        pub const openapi: ControllerDoc(@This()) = .{
            .tag = "Todos",
            .routes = .{ .get = .{ .summary = "Get a todo" } },
        };

        pub fn get(_: *TodosController, ctx: *http.Context) !http.Json(TodoResponse) {
            const in = try ctx.input(Get);
            if (in.path.id != 1) return error.TodoNotFound;
            return .{ .value = .{ .id = 1, .title = "Buy milk", .done = false } };
        }
    };

    const AppErrors = struct {
        pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
            return switch (err) {
                error.TodoNotFound => .{ .status = 404, .body = .{ .title = "Todo not found", .status = 404, .code = "todos.not_found" } },
                else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
            };
        }
    };

    var todos: TodosController = .{};
    var app_errors: AppErrors = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .prefix = "/api", .controllers = .{&todos}, .error_handler = &app_errors });
};

/// An answer to an error with an `http.Problem`, without its null fields.
fn problemJson(comptime status: []const u8, comptime name: []const u8, comptime title: []const u8, comptime code: []const u8) []const u8 {
    return "\"" ++ status ++ "\":{\"description\":\"" ++ comptime phraseOf(status) ++ "\",\"content\":{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/Problem\"}," ++
        "\"examples\":{\"" ++ name ++ "\":{\"value\":{\"type\":\"about:blank\",\"title\":\"" ++ title ++ "\",\"status\":" ++ status ++ ",\"code\":\"" ++ code ++ "\",\"errors\":[]}}}}}}";
}

fn phraseOf(comptime status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "400")) return "Bad Request";
    if (std.mem.eql(u8, status, "404")) return "Not Found";
    if (std.mem.eql(u8, status, "422")) return "Unprocessable Content";
    if (std.mem.eql(u8, status, "500")) return "Internal Server Error";
    unreachable;
}

test "the application of design §3: the whole document" {
    const doc = comptime document(small.Options, .{ .info = info });
    try testing.expect(!doc.runtime_prefix);
    try expectJson(comptime "{\"openapi\":\"3.1.2\",\"info\":{\"title\":\"Todos API\",\"version\":\"1.0.0\"},\"servers\":[{\"url\":\"/api\"}],\"tags\":[{\"name\":\"Todos\"}]," ++
        "\"paths\":{\"/v1/todos/{id}\":{\"get\":{\"operationId\":\"Todos.get\",\"tags\":[\"Todos\"],\"summary\":\"Get a todo\"," ++
        "\"parameters\":[{\"name\":\"id\",\"in\":\"path\",\"required\":true,\"description\":\"The id of the todo.\",\"example\":1,\"schema\":{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":1}}]," ++
        "\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/TodoResponse\"}}}}," ++
        problemJson("400", "InvalidRequest", "Bad Request", "invalid_request") ++ "," ++
        problemJson("404", "TodoNotFound", "Todo not found", "todos.not_found") ++ "," ++
        problemJson("422", "ValidationFailed", "Unprocessable Content", "validation_failed") ++ "," ++
        problemJson("500", "internal", "Internal Server Error", "internal") ++ "}}}}," ++
        "\"components\":{\"schemas\":{" ++
        "\"Problem\":{\"type\":\"object\",\"required\":[\"type\",\"title\",\"status\",\"code\",\"errors\"],\"properties\":{" ++
        "\"type\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"status\":{\"type\":\"integer\",\"format\":\"uint16\",\"minimum\":0,\"maximum\":65535}," ++
        "\"detail\":{\"type\":\"string\"},\"instance\":{\"type\":\"string\"},\"code\":{\"type\":\"string\"}," ++
        "\"errors\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/Violation\"}}}}," ++
        "\"TodoResponse\":{\"type\":\"object\",\"description\":\"A todo, as the API shows it.\",\"required\":[\"id\",\"title\",\"done\"],\"properties\":{" ++
        "\"id\":{\"type\":\"integer\",\"format\":\"uint64\",\"description\":\"The id of the todo.\",\"minimum\":0}," ++
        "\"title\":{\"type\":\"string\",\"description\":\"What to do.\"},\"done\":{\"type\":\"boolean\",\"description\":\"Whether it is done.\"}}}," ++
        "\"Violation\":{\"type\":\"object\",\"required\":[\"code\",\"message\"],\"properties\":{\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"field\":{\"type\":\"string\"}}}" ++
        "}}}", doc.root);
}

/// A route of each row of the table of design §7, none of them with an
/// error, so that only what they declare is in their responses.
const rows = struct {
    const Item = struct { id: u64 };
    const Receipt = struct { total: u32 };

    const ItemsController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/items",
            .methods = .{
                .list = http.get("", .{}),
                .create = http.post("", .{ .responses = .{ .created = .{}, .ok = .{} } }),
                .show = http.get("/{id}", .{ .responses = .{ .ok = .{}, .found = .{} } }),
                .remove = http.delete("/{id}", .{}),
                .exportCsv = http.get("/export.csv", .{ .responses = .{ .ok = .{ .content_type = "text/csv" } } }),
                .receipt = http.get("/receipt", .{ .responses = .{ .ok = .{ .json = Receipt } } }),
                .old = http.get("/old", .{ .responses = .{ .see_other = .{} } }),
            },
        });

        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{
            .list = .{ .summary = "List items" },
            .create = .{ .summary = "Create an item", .responses = .{ .ok = .{ .description = "The item made the first time." } } },
            .show = .{ .summary = "Show an item" },
            .remove = .{ .summary = "Remove an item" },
            .exportCsv = .{ .summary = "Export the items", .responses = .{ .ok = .{ .description = "All items, a row each." } } },
            .receipt = .{ .summary = "The receipt" },
            .old = .{ .summary = "The old page" },
        } };

        pub fn list(_: *ItemsController, _: *http.Context) error{}!http.Json(Item) {
            return .{ .value = .{ .id = 1 } };
        }
        pub fn create(_: *ItemsController, _: *http.Context) error{}!http.Json(Item) {
            return .{ .value = .{ .id = 1 }, .status = 201 };
        }
        pub fn show(_: *ItemsController, _: *http.Context) error{}!http.Json(Item) {
            return .{ .value = .{ .id = 1 } };
        }
        pub fn remove(_: *ItemsController, _: *http.Context) error{}!void {}
        pub fn exportCsv(_: *ItemsController, _: *http.Context) error{}!void {}
        pub fn receipt(_: *ItemsController, _: *http.Context) error{}!void {}
        pub fn old(_: *ItemsController, _: *http.Context) error{}!void {}
    };

    var items: ItemsController = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items} });
};

const item_json = "{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Item\"}}}";
const internal_500 = problemJson("500", "internal", "Internal Server Error", "internal");

test "success responses: each row of the table of design §7" {
    const paths = comptime at(document(rows.Options, .{ .info = info }).root, &.{"paths"});
    // http.Json(T): 200 with T.
    // A JSON value: writing it may run out of memory, a 500 of the server.
    try expectJson(comptime "{\"200\":{\"description\":\"OK\",\"content\":" ++ item_json ++ "}," ++ internal_500 ++ "}", comptime at(paths, &.{ "/items", "get", "responses" }));
    // .{ .created = .{}, .ok = .{} }: both with T, by status; the text of the ControllerDoc.
    try expectJson(comptime "{\"200\":{\"description\":\"The item made the first time.\",\"content\":" ++ item_json ++ "}," ++
        "\"201\":{\"description\":\"Created\",\"content\":" ++ item_json ++ "}," ++ internal_500 ++ "}", comptime at(paths, &.{ "/items", "post", "responses" }));
    // .{ .ok = .{}, .found = .{} }: 200 with T, 302 without a body.
    try expectJson(comptime "{\"200\":{\"description\":\"OK\",\"content\":" ++ item_json ++ "},\"302\":{\"description\":\"Found\"}," ++ internal_500 ++ "}", comptime at(paths, &.{ "/items/{id}", "get", "responses" }));
    // !void: 204.
    try expectJson("{\"204\":{\"description\":\"No Content\"}}", comptime at(paths, &.{ "/items/{id}", "delete", "responses" }));
    // A body the handler writes itself: a string of its media type.
    try expectJson("{\"200\":{\"description\":\"All items, a row each.\",\"content\":{\"text/csv\":{\"schema\":{\"type\":\"string\"}}}}}", comptime at(paths, &.{ "/items/export.csv", "get", "responses" }));
    // JSON the handler writes itself: .json = U.
    try expectJson("{\"200\":{\"description\":\"OK\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Receipt\"}}}}}", comptime at(paths, &.{ "/items/receipt", "get", "responses" }));
    // A redirect.
    try expectJson("{\"303\":{\"description\":\"See Other\"}}", comptime at(paths, &.{ "/items/old", "get", "responses" }));
    // The operations of one path, in the order of .methods; no HEAD of a GET, no OPTIONS.
    try testing.expectEqualStrings("get post", comptime keysOf(at(paths, &.{"/items"})));
    try testing.expectEqualStrings("get delete", comptime keysOf(at(paths, &.{"/items/{id}"})));
    try testing.expectEqualStrings("/items /items/{id} /items/export.csv /items/receipt /items/old", comptime keysOf(paths));
}

/// Statuses that go without content: a JSON route that also answers 204,
/// 205 and 304, a middleware that declares a body on its 204, and an error
/// that mapError answers with 304.
const bodiless = struct {
    const Item = struct { id: u64 };
    /// Only the 204 of the middleware names it: no schema of its own.
    const Unused = struct { note: []const u8 };

    const Conditional = struct {
        pub const openapi: MiddlewareDoc = .{ .responses = .{ .no_content = .{ .description = "Nothing to sync.", .json = Unused } } };

        pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };

    const ItemsController = struct {
        pub const http_routes = http.routes(.{ .prefix = "/items", .methods = .{
            .sync = http.put("/sync", .{ .responses = .{ .ok = .{}, .no_content = .{}, .reset_content = .{}, .not_modified = .{} }, .middleware = .{Conditional} }),
        } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .sync = .{ .summary = "Sync the items" } } };

        pub fn sync(_: *ItemsController, _: *http.Context) error{ItemUnchanged}!http.Json(Item) {
            return .{ .value = .{ .id = 1 } };
        }
    };

    const AppErrors = struct {
        pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
            return switch (err) {
                error.ItemUnchanged => .{ .status = 304, .body = .{ .title = "Not modified", .status = 304, .code = "items.unchanged" } },
                else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
            };
        }
    };

    var items: ItemsController = .{};
    var app_errors: AppErrors = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items}, .error_handler = &app_errors });
};

test "204, 205 and 304 have no content, whatever the handler, a middleware or mapError gives them" {
    const doc = comptime document(bodiless.Options, .{ .info = info });
    const responses = comptime at(doc.root, &.{ "paths", "/items/sync", "put", "responses" });
    try expectJson(comptime "{\"200\":{\"description\":\"OK\",\"content\":" ++ item_json ++ "}," ++
        "\"204\":{\"description\":\"Nothing to sync.\"}," ++
        "\"205\":{\"description\":\"Reset Content\"}," ++
        "\"304\":{\"description\":\"Not Modified\"}," ++ internal_500 ++ "}", responses);
    // The body of the middleware's 204 is in no response: no schema of it.
    try testing.expectEqualStrings("Item Problem Violation", comptime keysOf(at(doc.root, &.{ "components", "schemas" })));
}

/// The answers to errors: an error handler of the application, with a body
/// of its own.
const errs = struct {
    const ApiError = struct {
        code: []const u8,
        message: []const u8,
        trace_id: ?[]const u8 = null,

        pub const field_rules = .{ .trace_id = v.rename("traceId") };
    };

    const ItemsController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/items",
            .methods = .{
                // A 401 of its own besides the JSON one of its errors: an HTML page.
                .remove = http.delete("/{id}", .{ .responses = .{ .no_content = .{}, .unauthorized = .{ .content_type = "text/html" } } }),
            },
        });

        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .remove = .{ .summary = "Remove an item" } } };

        pub fn remove(_: *ItemsController, ctx: *http.Context) error{ ItemNotFound, ItemLocked, ItemArchived, PaymentGatewayDown, OutOfMemory, Unauthenticated, Canceled }!void {
            return switch (ctx.request.path.len) {
                1 => error.ItemNotFound,
                2 => error.ItemLocked,
                3 => error.ItemArchived,
                4 => error.PaymentGatewayDown,
                5 => error.OutOfMemory,
                6 => error.Unauthenticated,
                7 => error.Canceled,
                else => {},
            };
        }
    };

    const AppErrors = struct {
        pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
            return switch (err) {
                error.ItemNotFound => .{ .status = 404, .body = .{ .code = "items.not_found", .message = "No such item." } },
                error.ItemLocked, error.ItemArchived => .{ .status = 409, .body = .{ .code = "items.frozen", .message = "The item cannot change." } },
                error.PaymentGatewayDown => .{ .status = 500, .body = .{ .code = "payments.unavailable", .message = "Payments are down." } },
                else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
            };
        }
    };

    var items: ItemsController = .{};
    var app_errors: AppErrors = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items}, .error_handler = &app_errors });
};

fn apiError(comptime examples: []const u8) []const u8 {
    return "\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/ApiError\"},\"examples\":{" ++ examples ++ "}}";
}

test "answers to errors: a response per status, an example per body by the name of its error, 500 without internal names" {
    const doc = comptime document(errs.Options, .{ .info = info });
    try expectJson(comptime "{\"204\":{\"description\":\"No Content\"}," ++
        // The page of the route and the JSON of its errors, under one status.
        "\"401\":{\"description\":\"Unauthorized\",\"content\":{\"text/html\":{\"schema\":{\"type\":\"string\"}}," ++
        apiError("\"Unauthenticated\":{\"value\":{\"code\":\"unauthenticated\",\"message\":\"Unauthorized\",\"traceId\":null}}") ++ "}}," ++
        "\"404\":{\"description\":\"Not Found\",\"content\":{" ++
        apiError("\"ItemNotFound\":{\"value\":{\"code\":\"items.not_found\",\"message\":\"No such item.\",\"traceId\":null}}") ++ "}}," ++
        // Two errors of one body: one example, under the first name.
        "\"409\":{\"description\":\"Conflict\",\"content\":{" ++
        apiError("\"ItemArchived\":{\"value\":{\"code\":\"items.frozen\",\"message\":\"The item cannot change.\",\"traceId\":null}}") ++ "}}," ++
        // The branch of mapError, then all that its fallback gives 500.
        "\"500\":{\"description\":\"Internal Server Error\",\"content\":{" ++
        apiError("\"PaymentGatewayDown\":{\"value\":{\"code\":\"payments.unavailable\",\"message\":\"Payments are down.\",\"traceId\":null}}," ++
            "\"internal\":{\"value\":{\"code\":\"internal\",\"message\":\"Internal Server Error\",\"traceId\":null}}") ++ "}}}", comptime at(doc.root, &.{ "paths", "/items/{id}", "delete", "responses" }));
    // The body of an application's error writes its null fields.
    try expectJson("{\"type\":\"object\",\"required\":[\"code\",\"message\",\"traceId\"],\"properties\":{\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"},\"traceId\":{\"type\":[\"string\",\"null\"]}}}", comptime at(doc.root, &.{ "components", "schemas", "ApiError" }));
}

/// Security from the middleware of the chains, as design §9 has it.
const secure = struct {
    /// Knows the client by a bearer token or the cookie of a session.
    const TokenAuth = struct {
        pub const openapi: MiddlewareDoc = .{
            .security_schemes = &.{
                .{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "opaque" } } },
                .{ .name = "session", .description = "The cookie of a signed-in browser.", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } },
            },
        };

        pub fn run(_: *TokenAuth, _: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };

    /// The other kinds of schemes.
    const Federated = struct {
        pub const openapi: MiddlewareDoc = .{
            .security_schemes = &.{
                .{ .name = "oauth", .kind = .{ .oauth2 = .{ .flows = .{
                    .authorization_code = .{
                        .authorization_url = "https://id.example.com/authorize",
                        .token_url = "https://id.example.com/token",
                        .scopes = &.{.{ .name = "todos", .description = "The todos of the user." }},
                    },
                    .client_credentials = .{ .token_url = "https://id.example.com/token" },
                } } } },
                .{ .name = "oidc", .kind = .{ .open_id_connect = .{ .url = "https://id.example.com/.well-known/openid-configuration" } } },
                .{ .name = "mtls", .kind = .mutual_tls },
            },
        };

        pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };

    /// A 401 without a user; it answers some itself.
    const requireUser = struct {
        pub const openapi: MiddlewareDoc = .{ .security = .any, .responses = .{ .unauthorized = .{ .description = "Sign in first." } } };

        pub fn run(_: *http.Context) error{Unauthenticated}!http.MiddlewareResult {
            return .next;
        }
    };

    /// Bearer tokens only.
    const requireBearer = struct {
        pub const openapi: MiddlewareDoc = .{ .security = .{ .schemes = &.{"bearer"} } };

        pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };

    fn requirePermission(comptime permission: []const u8) type {
        return struct {
            pub const name = "requirePermission(" ++ permission ++ ")";
            pub const openapi: MiddlewareDoc = .{ .roles = &.{permission} };

            pub fn run(_: *http.Context) error{PermissionDenied}!http.MiddlewareResult {
                return .next;
            }
        };
    }

    const TodosController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/todos",
            .middleware = .{ requireUser, requirePermission("todos") },
            .methods = .{
                .list = http.get("", .{}),
                .delete = http.delete("/{id}", .{ .middleware = .{requirePermission("todos:delete")} }),
                .admin = http.get("/admin", .{ .middleware = .{ requireBearer, requirePermission("todos") } }),
            },
        });

        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{
            .list = .{ .summary = "List todos" },
            .delete = .{ .summary = "Delete a todo" },
            .admin = .{ .summary = "Administer todos" },
        } };

        pub fn list(_: *TodosController, _: *http.Context) error{}!void {}
        pub fn delete(_: *TodosController, _: *http.Context) error{}!void {}
        pub fn admin(_: *TodosController, _: *http.Context) error{}!void {}
    };

    const HealthController = struct {
        pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{ .middleware = .{Federated} }) } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .check = .{ .summary = "Check" } } };

        pub fn check(_: *HealthController, _: *http.Context) error{}!void {}
    };

    var token_auth: TokenAuth = .{};
    var todos: TodosController = .{};
    var health: HealthController = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{ &todos, &health }, .middleware = .{&token_auth} });
};

test "security: the schemes of the chains, a route's requirement with its roles, public routes without one" {
    const doc = comptime document(secure.Options, .{ .info = info });
    const paths = comptime at(doc.root, &.{"paths"});
    // .any: each scheme declared before it, with the roles of the chain.
    try expectJson("[{\"bearer\":[\"todos\"]},{\"session\":[\"todos\"]}]", comptime at(paths, &.{ "/todos", "get", "security" }));
    try expectJson("[{\"bearer\":[\"todos\",\"todos:delete\"]},{\"session\":[\"todos\",\"todos:delete\"]}]", comptime at(paths, &.{ "/todos/{id}", "delete", "security" }));
    // Schemes by name; a role given twice once.
    try expectJson("[{\"bearer\":[\"todos\"]}]", comptime at(paths, &.{ "/todos/admin", "get", "security" }));
    // No .security in its chain: public.
    try testing.expectEqualStrings("operationId tags summary responses", comptime keysOf(at(paths, &.{ "/health", "get" })));
    // Every scheme of every chain, by name.
    try expectJson("{\"bearer\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"opaque\"}," ++
        "\"mtls\":{\"type\":\"mutualTLS\"}," ++
        "\"oauth\":{\"type\":\"oauth2\",\"flows\":{\"clientCredentials\":{\"tokenUrl\":\"https://id.example.com/token\",\"scopes\":{}}," ++
        "\"authorizationCode\":{\"authorizationUrl\":\"https://id.example.com/authorize\",\"tokenUrl\":\"https://id.example.com/token\",\"scopes\":{\"todos\":\"The todos of the user.\"}}}}," ++
        "\"oidc\":{\"type\":\"openIdConnect\",\"openIdConnectUrl\":\"https://id.example.com/.well-known/openid-configuration\"}," ++
        "\"session\":{\"type\":\"apiKey\",\"description\":\"The cookie of a signed-in browser.\",\"name\":\"session\",\"in\":\"cookie\"}}", comptime at(doc.root, &.{ "components", "securitySchemes" }));
    // A response the middleware writes itself, with its text, joins the 401 of its error.
    try expectJson(comptime "{\"description\":\"Sign in first.\",\"content\":{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/Problem\"}," ++
        "\"examples\":{\"Unauthenticated\":{\"value\":{\"type\":\"about:blank\",\"title\":\"Unauthorized\",\"status\":401,\"code\":\"unauthenticated\",\"errors\":[]}}}}}}", comptime at(paths, &.{ "/todos", "get", "responses", "401" }));
    try testing.expectEqualStrings("204 401 403", comptime keysOf(at(paths, &.{ "/todos", "get", "responses" })));
}

/// A stream of events.
const live = struct {
    const TodoResponse = struct { id: u64, title: []const u8 };
    const TodoIdPath = struct { id: u64 };
    const LiveEvent = union(enum) {
        @"todo.created": TodoResponse,
        @"todo.deleted": TodoIdPath,
        ping,
        count: u32,
    };

    const LiveController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/todos",
            .methods = .{ .events = http.sse.get("/events", .{ .events = LiveEvent }) },
        });

        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{
            .events = .{ .summary = "Live updates", .responses = .{ .ok = .{ .description = "The changes, as they happen." } } },
        } };

        pub fn events(_: *LiveController, _: *http.sse.Context) error{}!void {}
    };

    /// The same stream, without a text of its response.
    const PlainController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/todos",
            .methods = .{ .events = http.sse.get("/events", .{ .events = LiveEvent }) },
        });

        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .events = .{ .summary = "Live updates" } } };

        pub fn events(_: *PlainController, _: *http.sse.Context) error{}!void {}
    };

    var controller: LiveController = .{};
    var plain: PlainController = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&controller} });
    const Plain = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&plain} });
};

test "SSE in 3.1: a string, and the events with the schemas of their data in the description; 204 without a stream" {
    // Without a text of the route, the events are the description.
    const plain = comptime document(live.Plain, .{ .info = info });
    try expectJson("\"The events of the stream, each with the schema of its data: todo.created (TodoResponse), todo.deleted (TodoIdPath), ping (an empty object), count (an integer).\"", comptime at(plain.root, &.{ "paths", "/todos/events", "get", "responses", "200", "description" }));
    const doc = comptime document(live.Options, .{ .info = info });
    try expectJson("{\"200\":{\"description\":\"The changes, as they happen. The events of the stream, each with the schema of its data: " ++
        "todo.created (TodoResponse), todo.deleted (TodoIdPath), ping (an empty object), count (an integer).\"," ++
        "\"content\":{\"text/event-stream\":{\"schema\":{\"type\":\"string\"}}}}," ++
        // A handler that returns without subscribe: an EventSource stops
        // reconnecting.
        "\"204\":{\"description\":\"No Content\"}}", comptime at(doc.root, &.{ "paths", "/todos/events", "get", "responses" }));
    // The schemas of the data, for the generators of clients.
    try testing.expectEqualStrings("TodoIdPath TodoResponse", comptime keysOf(at(doc.root, &.{ "components", "schemas" })));
}

/// An event of 3.2's `itemSchema`.
fn event(comptime name: []const u8, comptime data: []const u8) []const u8 {
    return "{\"type\":\"object\",\"required\":[\"event\",\"data\"],\"properties\":{\"event\":{\"type\":\"string\",\"const\":\"" ++ name ++ "\"}," ++
        "\"data\":{\"type\":\"string\",\"contentMediaType\":\"application/json\",\"contentSchema\":" ++ data ++ "}," ++
        "\"id\":{\"type\":\"string\"},\"retry\":{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":0}}}";
}

test "SSE in 3.2: itemSchema, one of the events, each with its data" {
    const doc = comptime document(live.Options, .{ .info = info, .version = .@"3.2" });
    try expectJson("\"3.2.1\"", comptime at(doc.root, &.{"openapi"}));
    try expectJson(comptime "{\"200\":{\"description\":\"The changes, as they happen.\",\"content\":{\"text/event-stream\":{\"itemSchema\":{\"oneOf\":[" ++
        event("todo.created", "{\"$ref\":\"#/components/schemas/TodoResponse\"}") ++ "," ++
        event("todo.deleted", "{\"$ref\":\"#/components/schemas/TodoIdPath\"}") ++ "," ++
        event("ping", "{\"type\":\"object\",\"maxProperties\":0}") ++ "," ++
        event("count", "{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}") ++
        "]}}}},\"204\":{\"description\":\"No Content\"}}", comptime at(doc.root, &.{ "paths", "/todos/events", "get", "responses" }));
}

/// A controller of a route, a controller without texts, a controller of
/// documentation, and static files.
const parts = struct {
    const ItemsController = struct {
        pub const http_routes = http.routes(.{ .prefix = "/items", .methods = .{ .list = http.get("", .{}) } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List items" } } };

        pub fn list(_: *ItemsController, _: *http.Context) error{}!void {}
    };

    const HealthController = struct {
        pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });

        pub fn check(_: *HealthController, _: *http.Context) error{}!void {}
    };

    /// As `zefir.openapi.Docs` marks itself.
    const DocsController = struct {
        pub const zefir_openapi_docs = {};
        pub const http_routes = http.routes(.{ .methods = .{ .json = http.get("/openapi.json", .{}) } });

        pub fn json(_: *DocsController, _: *http.Context) error{}!void {}
    };

    var items: ItemsController = .{};
    var health: HealthController = .{};
    var docs: DocsController = .{};
    const static = .{http.static("/", .{ .root = "public" })};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{ &items, &health, &docs }, .static = static });
};

test "what goes in: .exclude or .include, never Docs or static files" {
    const excluded = comptime document(parts.Options, .{ .info = info, .exclude = &.{parts.HealthController} });
    try testing.expectEqualStrings("/items", comptime keysOf(at(excluded.root, &.{"paths"})));
    const included = comptime document(parts.Options, .{ .info = info, .include = &.{parts.ItemsController} });
    try testing.expectEqualStrings("/items", comptime keysOf(at(included.root, &.{"paths"})));
    // No prefix: no servers; nothing comes at run time.
    try testing.expectEqualStrings("openapi info tags paths", comptime keysOf(excluded.root));
    try testing.expect(!excluded.runtime_prefix);
}

test "servers: the prefix known at compile time, from the config, or .servers" {
    var config_prefix: []const u8 = "/api";
    _ = &config_prefix;
    const Runtime = @TypeOf(.{ .backend = @as(http.Backend, undefined), .prefix = config_prefix, .controllers = .{&parts.items} });
    const runtime = comptime document(Runtime, .{ .info = info });
    try testing.expect(runtime.runtime_prefix);
    try testing.expectEqualStrings("openapi info tags paths", comptime keysOf(runtime.root));
    const given = comptime document(Runtime, .{ .info = info, .servers = &.{
        .{ .url = "https://api.example.com/v1", .description = "Production" },
        .{ .url = "http://localhost:8080/api" },
    } });
    try testing.expect(!given.runtime_prefix);
    try expectJson("[{\"url\":\"https://api.example.com/v1\",\"description\":\"Production\"},{\"url\":\"http://localhost:8080/api\"}]", comptime at(given.root, &.{"servers"}));
}

/// Tags shared and given by default, operationIds and the texts of
/// operations.
const named = struct {
    const TodosV1Controller = struct {
        pub const http_routes = http.routes(.{ .prefix = "/v1/todos", .methods = .{
            .list = http.get("", .{}),
            .purge = http.delete("", .{}),
        } });
        pub const openapi: ControllerDoc(@This()) = .{ .tag = "Todos", .routes = .{
            .list = .{ .summary = "List todos", .description = "The todos of the signed-in user.", .operation_id = "listTodos" },
            .purge = .{ .summary = "Delete every todo", .deprecated = true },
        } };

        pub fn list(_: *TodosV1Controller, _: *http.Context) error{}!void {}
        pub fn purge(_: *TodosV1Controller, _: *http.Context) error{}!void {}
    };

    const HealthController = struct {
        pub const http_routes = http.routes(.{ .methods = .{ .check = http.get("/health", .{}) } });
        pub const openapi: ControllerDoc(@This()) = .{ .description = "Whether the service is up.", .routes = .{ .check = .{ .summary = "Check" } } };

        pub fn check(_: *HealthController, _: *http.Context) error{}!void {}
    };

    const TodosV2Controller = struct {
        pub const http_routes = http.routes(.{ .prefix = "/v2/todos", .methods = .{ .list = http.get("", .{}) } });
        pub const openapi: ControllerDoc(@This()) = .{ .tag = "Todos", .description = "The todos of the signed-in user.", .routes = .{ .list = .{ .summary = "List todos" } } };

        pub fn list(_: *TodosV2Controller, _: *http.Context) error{}!void {}
    };

    var v1: TodosV1Controller = .{};
    var health: HealthController = .{};
    var v2: TodosV2Controller = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{ &v1, &health, &v2 } });
};

test "tags in the order they first come, shared and by default; operationIds; the texts of operations" {
    const doc = comptime document(named.Options, .{ .info = .{
        .title = "Todos API",
        .version = "1.0.0",
        .description = "Todos of their users.",
        .contact = .{ .name = "The todos team", .email = "todos@example.com" },
        .license = .{ .name = "MIT", .identifier = "MIT" },
    } });
    try expectJson("{\"title\":\"Todos API\",\"version\":\"1.0.0\",\"description\":\"Todos of their users.\",\"contact\":{\"name\":\"The todos team\",\"email\":\"todos@example.com\"},\"license\":{\"name\":\"MIT\",\"identifier\":\"MIT\"}}", comptime at(doc.root, &.{"info"}));
    // One tag of two controllers, its description from the one that gives it.
    try expectJson("[{\"name\":\"Todos\",\"description\":\"The todos of the signed-in user.\"},{\"name\":\"Health\",\"description\":\"Whether the service is up.\"}]", comptime at(doc.root, &.{"tags"}));
    const paths = comptime at(doc.root, &.{"paths"});
    try expectJson("{\"operationId\":\"listTodos\",\"tags\":[\"Todos\"],\"summary\":\"List todos\",\"description\":\"The todos of the signed-in user.\",\"responses\":{\"204\":{\"description\":\"No Content\"}}}", comptime at(paths, &.{ "/v1/todos", "get" }));
    try expectJson("{\"operationId\":\"TodosV1.purge\",\"tags\":[\"Todos\"],\"summary\":\"Delete every todo\",\"deprecated\":true,\"responses\":{\"204\":{\"description\":\"No Content\"}}}", comptime at(paths, &.{ "/v1/todos", "delete" }));
    try expectJson("\"Health.check\"", comptime at(paths, &.{ "/health", "get", "operationId" }));
    try expectJson("\"TodosV2.list\"", comptime at(paths, &.{ "/v2/todos", "get", "operationId" }));
}

/// Parameters of each place, of the template, and of a middleware.
const params = struct {
    const Sort = enum { asc, desc };
    const Theme = enum { light, dark };

    /// Two parameters, one of them renamed.
    const ProjectTodoPath = struct {
        project_id: u64,
        id: u64,

        pub const field_rules = .{
            .project_id = .{ v.rename("projectId"), v.positive },
            .id = v.positive,
        };

        pub const openapi: Doc(@This()) = .{ .fields = .{
            .project_id = .{ .description = "The id of the project.", .example = 7 },
            .id = .{ .description = "The id of the todo in the project.", .example = 42 },
        } };
    };

    const ListQuery = struct {
        tags: []const []const u8 = &.{},
        sort: Sort = .asc,
        q: ?[]const u8 = null,
        from: u32,
        to: u32,

        pub const field_rules = .{ .tags = v.each(v.maxLength(30)), .q = .{ v.trim, v.maxLength(100) } };

        pub fn validateSelf(self: *const ListQuery) ?v.Violation {
            if (self.from > self.to) return v.fail(ListQuery, .to, "periods.order", "must not be before from");
            return null;
        }

        pub const openapi: Doc(@This()) = .{ .fields = .{ .q = .{ .description = "Words to look for.", .example = "milk" } } };
    };

    const TraceHeaders = struct {
        x_trace: []const []const u8 = &.{},
        idempotency_key: ?[]const u8 = null,
    };

    const SessionCookies = struct {
        theme: Theme = .light,
        session_id: ?[]const u8 = null,
        recent: []const []const u8 = &.{},

        pub const field_rules = .{ .session_id = v.rename("sid") };
    };

    const PageQuery = struct { limit: u32 = 20 };

    /// Reads a page of its own.
    const Paging = struct {
        pub const openapi: MiddlewareDoc = .{ .query = PageQuery };

        pub fn run(_: *http.Context) error{}!http.MiddlewareResult {
            return .next;
        }
    };

    const ProjectTodosController = struct {
        pub const http_routes = http.routes(.{
            .prefix = "/v1/projects/{projectId}/todos",
            .methods = .{
                .get = http.get("/{id}", .{ .path = ProjectTodoPath, .query = ListQuery, .headers = TraceHeaders, .cookies = SessionCookies, .middleware = .{Paging} }),
                .files = http.get("/files/{*rest}", .{}),
            },
        });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{
            .get = .{ .summary = "Get a todo" },
            .files = .{ .summary = "Get a file" },
        } };

        pub fn get(_: *ProjectTodosController, _: *http.Context) error{}!void {}
        pub fn files(_: *ProjectTodosController, _: *http.Context) error{}!void {}
    };

    var controller: ProjectTodosController = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&controller} });
};

test "parameters: the path by outside names, the query, headers and cookies, those of a middleware" {
    const doc = comptime document(params.Options, .{ .info = info });
    const get = comptime at(doc.root, &.{ "paths", "/v1/projects/{projectId}/todos/{id}", "get" });
    try expectJson("\"The server also checks how these parameters fit together.\"", comptime at(get, &.{"description"}));
    const uint64 = "{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":1}";
    try expectJson("[" ++
        "{\"name\":\"projectId\",\"in\":\"path\",\"required\":true,\"description\":\"The id of the project.\",\"example\":7,\"schema\":" ++ uint64 ++ "}," ++
        "{\"name\":\"id\",\"in\":\"path\",\"required\":true,\"description\":\"The id of the todo in the project.\",\"example\":42,\"schema\":" ++ uint64 ++ "}," ++
        // A list in the query: one name a value.
        "{\"name\":\"tags\",\"in\":\"query\",\"required\":false,\"style\":\"form\",\"explode\":true,\"schema\":{\"type\":\"array\",\"default\":[],\"items\":{\"type\":\"string\",\"maxLength\":30}}}," ++
        "{\"name\":\"sort\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"string\",\"enum\":[\"asc\",\"desc\"],\"default\":\"asc\"}}," ++
        "{\"name\":\"q\",\"in\":\"query\",\"required\":false,\"description\":\"Words to look for. Leading and trailing spaces are removed.\",\"example\":\"milk\",\"schema\":{\"type\":\"string\",\"maxLength\":100}}," ++
        "{\"name\":\"from\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}}," ++
        "{\"name\":\"to\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}}," ++
        // A list in a header: a line of the header an item.
        "{\"name\":\"X-Trace\",\"in\":\"header\",\"required\":false,\"description\":\"The server reads an item from each line of this header and does not split a line at commas.\",\"style\":\"simple\",\"explode\":false,\"schema\":{\"type\":\"array\",\"default\":[],\"items\":{\"type\":\"string\"}}}," ++
        "{\"name\":\"Idempotency-Key\",\"in\":\"header\",\"required\":false,\"schema\":{\"type\":\"string\"}}," ++
        "{\"name\":\"theme\",\"in\":\"cookie\",\"required\":false,\"schema\":{\"type\":\"string\",\"enum\":[\"light\",\"dark\"],\"default\":\"light\"}}," ++
        "{\"name\":\"sid\",\"in\":\"cookie\",\"required\":false,\"schema\":{\"type\":\"string\"}}," ++
        // A list in a cookie: the server reads the first cookie of the name.
        "{\"name\":\"recent\",\"in\":\"cookie\",\"required\":false,\"description\":\"The server reads only the first cookie of this name: a list of one item.\"," ++
        "\"style\":\"form\",\"explode\":true,\"schema\":{\"type\":\"array\",\"maxItems\":1,\"default\":[],\"items\":{\"type\":\"string\"}}}," ++
        // What the middleware reads, after the route's own.
        "{\"name\":\"limit\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295,\"default\":20}}" ++
        "]", comptime at(get, &.{"parameters"}));
    // Without .path: the parameters of the template, strings; the rest of the path may hold '/'.
    try expectJson("[{\"name\":\"projectId\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}," ++
        "{\"name\":\"rest\",\"in\":\"path\",\"required\":true,\"description\":\"The rest of the path, which may hold '/'.\",\"schema\":{\"type\":\"string\"}}]", comptime at(doc.root, &.{ "paths", "/v1/projects/{projectId}/todos/files/{rest}", "get", "parameters" }));
}

/// Bodies of JSON and of a form, with named examples.
const bodies = struct {
    const CreateTodoRequest = struct {
        title: []const u8,
        due_date: ?[]const u8 = null,

        pub const field_rules = .{ .due_date = .{ v.rename("dueDate"), v.date } };

        pub const openapi: Doc(@This()) = .{ .examples = &.{
            .{ .name = "minimal", .summary = "Only a title", .value = .{ .title = "Buy milk" } },
            .{ .name = "dated", .value = .{ .title = "Pay rent", .due_date = "2026-11-01" } },
        } };
    };

    const TodoResponse = struct {
        id: u64,

        pub const openapi: Doc(@This()) = .{ .examples = &.{.{ .name = "first", .value = .{ .id = 1 } }} };
    };

    const LoginForm = struct { user: []const u8, password: []const u8 };

    /// A constant in the JSON it writes, which a body it reads leaves out.
    const Note = struct {
        comptime kind: []const u8 = "note",
        text: []const u8,

        pub const openapi: Doc(@This()) = .{ .examples = &.{.{ .name = "short", .value = .{ .text = "Call back" } }} };
    };

    const TodosController = struct {
        pub const http_routes = http.routes(.{ .prefix = "/todos", .methods = .{
            .create = http.post("", .{ .body = CreateTodoRequest, .responses = .{ .created = .{} } }),
            .login = http.post("/login", .{ .form = LoginForm, .responses = .{ .see_other = .{} } }),
            .note = http.post("/notes", .{ .body = Note }),
        } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{
            .create = .{ .summary = "Create a todo" },
            .login = .{ .summary = "Sign in" },
            .note = .{ .summary = "Add a note" },
        } };

        pub fn create(_: *TodosController, _: *http.Context) error{}!http.Json(TodoResponse) {
            return .{ .value = .{ .id = 1 }, .status = 201 };
        }
        pub fn login(_: *TodosController, _: *http.Context) error{}!void {}
        pub fn note(_: *TodosController, _: *http.Context) error{}!http.Json(Note) {
            return .{ .value = .{ .text = "Call back" } };
        }
    };

    var controller: TodosController = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&controller} });
};

test "request bodies: JSON and a form; the named examples of a body's type, on requests and responses" {
    const doc = comptime document(bodies.Options, .{ .info = info });
    const create = comptime at(doc.root, &.{ "paths", "/todos", "post" });
    try expectJson("{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/CreateTodoRequest\"},\"examples\":{" ++
        "\"minimal\":{\"summary\":\"Only a title\",\"value\":{\"title\":\"Buy milk\",\"dueDate\":null}}," ++
        "\"dated\":{\"value\":{\"title\":\"Pay rent\",\"dueDate\":\"2026-11-01\"}}}}}}", comptime at(create, &.{"requestBody"}));
    try expectJson("{\"description\":\"Created\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/TodoResponse\"},\"examples\":{\"first\":{\"value\":{\"id\":1}}}}}}", comptime at(create, &.{ "responses", "201" }));
    try expectJson("{\"required\":true,\"content\":{\"application/x-www-form-urlencoded\":{\"schema\":{\"$ref\":\"#/components/schemas/LoginForm\"}}}}", comptime at(doc.root, &.{ "paths", "/todos/login", "post", "requestBody" }));
    try expectJson("{\"type\":\"object\",\"required\":[\"user\",\"password\"],\"properties\":{\"user\":{\"type\":\"string\"},\"password\":{\"type\":\"string\"}},\"additionalProperties\":false}", comptime at(doc.root, &.{ "components", "schemas", "LoginForm" }));
    // A comptime field is in what the server writes, not in what it reads.
    const note = comptime at(doc.root, &.{ "paths", "/todos/notes", "post" });
    try expectJson("{\"short\":{\"value\":{\"text\":\"Call back\"}}}", comptime at(note, &.{ "requestBody", "content", "application/json", "examples" }));
    try expectJson("{\"short\":{\"value\":{\"kind\":\"note\",\"text\":\"Call back\"}}}", comptime at(note, &.{ "responses", "200", "content", "application/json", "examples" }));
}

test "Document.write: the bytes of the file, laid out, a newline at the end" {
    const doc = comptime document(parts.Options, .{ .info = info, .exclude = &.{parts.HealthController} });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try doc.write(&out.writer);
    try testing.expectEqualStrings(
        \\{
        \\  "openapi": "3.1.2",
        \\  "info": {
        \\    "title": "Todos API",
        \\    "version": "1.0.0"
        \\  },
        \\  "tags": [
        \\    {
        \\      "name": "Items"
        \\    }
        \\  ],
        \\  "paths": {
        \\    "/items": {
        \\      "get": {
        \\        "operationId": "Items.list",
        \\        "tags": [
        \\          "Items"
        \\        ],
        \\        "summary": "List items",
        \\        "responses": {
        \\          "204": {
        \\            "description": "No Content"
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , out.written());
}

/// A middleware that writes the body of an error itself, and an error
/// handler whose body writes itself.
const merged = struct {
    const ApiError = struct { code: []const u8 };

    /// Answers 429 itself, with the body of the error handler.
    const Limiter = struct {
        pub const openapi: MiddlewareDoc = .{ .responses = .{ .too_many_requests = .{ .description = "Slow down.", .json = ApiError } } };

        pub fn run(_: *http.Context) error{RateLimited}!http.MiddlewareResult {
            return .next;
        }
    };

    const ItemsController = struct {
        pub const http_routes = http.routes(.{ .prefix = "/items", .methods = .{ .list = http.get("", .{ .middleware = .{Limiter} }) } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List items" } } };

        pub fn list(_: *ItemsController, _: *http.Context) error{}!void {}
    };

    const AppErrors = struct {
        pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
            return .fallback(err, .{ .code = http.defaultCode(err) });
        }
    };

    /// Writes itself, as a string of its code.
    const Raw = struct {
        code: []const u8,

        pub fn jsonStringify(self: Raw, w: anytype) !void {
            try w.write(self.code);
        }

        pub const openapi: Doc(@This()) = .{ .as = []const u8 };
    };

    const RawErrors = struct {
        pub fn mapError(err: anyerror) http.ErrorResponse(Raw) {
            return .fallback(err, .{ .code = http.defaultCode(err) });
        }
    };

    const SecretsController = struct {
        pub const http_routes = http.routes(.{ .prefix = "/secrets", .methods = .{ .list = http.get("", .{}) } });
        pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List secrets" } } };

        pub fn list(_: *SecretsController, _: *http.Context) error{PermissionDenied}!void {}
    };

    var items: ItemsController = .{};
    var secrets: SecretsController = .{};
    var app_errors: AppErrors = .{};
    var raw_errors: RawErrors = .{};
    const Options = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&items}, .error_handler = &app_errors });
    const RawOptions = @TypeOf(.{ .backend = @as(http.Backend, undefined), .controllers = .{&secrets}, .error_handler = &raw_errors });
};

test "one status and media type of a middleware and of errors: one body, the examples of both" {
    const doc = comptime document(merged.Options, .{ .info = info });
    try expectJson("{\"description\":\"Slow down.\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/ApiError\"}," ++
        "\"examples\":{\"RateLimited\":{\"value\":{\"code\":\"rate_limited\"}}}}}}", comptime at(doc.root, &.{ "paths", "/items", "get", "responses", "429" }));
    // A body that writes itself has its JSON at run time only: no examples.
    const raw = comptime document(merged.RawOptions, .{ .info = info });
    try expectJson("{\"description\":\"Forbidden\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Raw\"}}}}", comptime at(raw.root, &.{ "paths", "/secrets", "get", "responses", "403" }));
    try expectJson("{\"type\":\"string\"}", comptime at(raw.root, &.{ "components", "schemas", "Raw" }));
}
