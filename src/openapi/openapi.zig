//! The declarations of a document: the typed `pub const openapi` of DTOs,
//! controllers and middleware, and the options of a document. The module
//! re-exports them; they live in a file of this name because the compiler
//! names a type after its file, so its messages read `openapi.Doc(...)`, as
//! an application writes them through `zefir.openapi`:
//!
//! ```text
//! dto.zig: error: no field named 'descripton' in struct 'openapi.FieldDoc(u64)'
//! ```
const std = @import("std");
const http = @import("http");

/// The texts and examples of a DTO, an enum or a `union(enum)`:
/// `pub const openapi: zefir.openapi.Doc(@This()) = .{ ... }`.
///
/// - `.name`: the name of its schema in the document, instead of the last
///   part of the type's name (`Page_TodoResponse` for
///   `Page(dto.TodoResponse)`);
/// - `.description`;
/// - `.example`: a value of the type, which the document shows as the
///   server writes it; `.examples`: named values, which a request or a
///   response with a body of the type shows;
/// - `.deprecated`;
/// - `.fields`: the texts of each field of a struct, or of each variant of a
///   union: `.fields = .{ .title = .{ .description = "What to do." } }`.
///   An enum has no `.fields`.
///
/// A type that writes itself, with a `jsonStringify` of its own, says what
/// its JSON looks like in `.as`, a type of the same JSON: `.as = []const u8`.
/// Its JSON exists only at run time, so it has no `.example` and no
/// `.fields`.
pub fn Doc(comptime T: type) type {
    if (writesItself(T)) return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        deprecated: bool = false,
        /// The type whose JSON this type writes: its schema is the
        /// type's.
        as: type,
    };
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (!s.is_tuple) return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
            fields: Fields = .{},

            /// A field for each field of the struct.
            pub const Fields = @Struct(.auto, null, s.field_names, &fieldDocTypes(s.field_types), &noDocs(s.field_types));
        },
        .@"union" => |u| if (u.tag_type != null) return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
            fields: Fields = .{},

            /// A field for each variant of the union.
            pub const Fields = @Struct(.auto, null, u.field_names, &fieldDocTypes(u.field_types), &noDocs(u.field_types));
        },
        .@"enum" => return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
        },
        else => {},
    }
    @compileError("zefir.openapi: Doc takes a struct, an enum or a union(enum), the types of JSON values; got " ++ @typeName(T));
}

/// The texts of a field of a struct or a variant of a union, of type `F`:
/// `.description`, `.example` (a value of `F`), `.examples` (more values)
/// and `.deprecated`. A field of a type that writes itself has no examples:
/// its JSON exists only at run time.
pub fn FieldDoc(comptime F: type) type {
    if (writesItself(F)) return struct {
        description: ?[]const u8 = null,
        deprecated: bool = false,
    };
    return struct {
        description: ?[]const u8 = null,
        example: ?F = null,
        examples: []const F = &.{},
        deprecated: bool = false,
    };
}

/// A named example of a body of type `T`, which a request or a response
/// shows under `name`.
pub fn Example(comptime T: type) type {
    return struct {
        name: []const u8,
        summary: ?[]const u8 = null,
        value: T,
    };
}

/// The texts of a controller: `pub const openapi:
/// zefir.openapi.ControllerDoc(@This()) = .{ ... }`.
///
/// - `.tag`: the tag of its routes; the controller's name without
///   `Controller` when left out (`TodosV1`);
/// - `.description`: the tag's;
/// - `.routes`: an entry for each method of `http_routes.methods`, none
///   left out, each with its `.summary` (see `RouteDoc`).
pub fn ControllerDoc(comptime C: type) type {
    return struct {
        tag: ?[]const u8 = null,
        description: ?[]const u8 = null,
        routes: Routes,

        /// A field for each method of the controller's routes.
        pub const Routes = @Struct(.auto, null, methodNames(C), &routeDocTypes(C), &@as([methodNames(C).len]std.lang.Type.Struct.FieldAttributes, @splat(.{})));
    };
}

/// The texts of the route of the method `method` of the controller `C`:
/// its `.summary`, which every route of the document has, `.description`,
/// `.operation_id` (`TodosV1.create` when left out), `.deprecated`, and
/// `.responses`, the descriptions of its responses by status:
/// `.responses = .{ .ok = .{ .description = "All todos, a row each." } }`.
/// Its statuses are those of its `.responses`, else its default one: 200
/// for a handler that returns `http.Json(T)` and for a stream, 204 for one
/// of `!void`. A status left out is described by its phrase, `OK`, as is
/// the 204 of a stream whose handler returns without `subscribe`.
pub fn RouteDoc(comptime C: type, comptime method: []const u8) type {
    return struct {
        summary: []const u8,
        description: ?[]const u8 = null,
        operation_id: ?[]const u8 = null,
        deprecated: bool = false,
        responses: Responses = .{},

        /// A field for each status of the route.
        pub const Responses = @Struct(.auto, null, statusNames(C, method), &@as([statusNames(C, method).len]type, @splat(?ResponseDoc)), &noResponses(statusNames(C, method).len));
    };
}

/// The description of a response of a route.
pub const ResponseDoc = struct { description: []const u8 };

/// What a middleware tells the document: `pub const openapi:
/// zefir.openapi.MiddlewareDoc = .{ ... }` in its type. A middleware that
/// is a function has no declarations: make it a type with `pub fn run`.
///
/// - `.security_schemes`: how it knows the client, each under its name;
/// - `.security`: a route behind it requires one of the schemes declared
///   before it in its chain, `.any`, or of those named, `.{ .schemes =
///   &.{"bearer"} }`;
/// - `.roles`: the roles it requires, added to each scheme of the
///   requirement;
/// - `.query`, `.headers`, `.cookies`: the DTOs it reads, which become
///   parameters of every route behind it;
/// - `.responses`: the responses it writes itself, with `.handled`, such as
///   a 304 or a 429, in the form of a route's `.responses`.
///
/// zefir-http reads `.query`, `.headers`, `.cookies` and `.responses` by
/// their names for its check in Debug, without importing this module.
pub const MiddlewareDoc = struct {
    security_schemes: []const SecurityScheme = &.{},
    security: ?Security = null,
    roles: []const []const u8 = &.{},
    query: type = void,
    headers: type = void,
    cookies: type = void,
    responses: Responses = .{},

    /// A way of signing in, under `name` in the document's
    /// `securitySchemes`.
    pub const SecurityScheme = struct { name: []const u8, description: ?[]const u8 = null, kind: Kind };
    pub const Kind = union(enum) { http: Http, api_key: ApiKey, oauth2: OAuth2, open_id_connect: OpenIdConnect, mutual_tls };
    /// `Authorization: <scheme> ...`: `.scheme = "bearer"`.
    pub const Http = struct { scheme: []const u8, bearer_format: ?[]const u8 = null };
    /// A key in a header, the query or a cookie of the name `param`.
    pub const ApiKey = struct { in: enum { header, query, cookie }, param: []const u8 };
    pub const OAuth2 = struct { flows: Flows };
    pub const Flows = struct { implicit: ?Flow = null, password: ?Flow = null, client_credentials: ?Flow = null, authorization_code: ?Flow = null };
    pub const Flow = struct { authorization_url: ?[]const u8 = null, token_url: ?[]const u8 = null, refresh_url: ?[]const u8 = null, scopes: []const Scope = &.{} };
    pub const Scope = struct { name: []const u8, description: []const u8 };
    pub const OpenIdConnect = struct { url: []const u8 };
    /// What a route behind the middleware requires: any scheme declared
    /// before it in the chain, or those named.
    pub const Security = union(enum) { any, schemes: []const []const u8 };
    /// A field for each status of `std.http.Status`, null for those the
    /// middleware does not answer with.
    pub const Responses = @Struct(.auto, null, status_names, &@as([status_names.len]type, @splat(?Response)), &noMiddlewareResponses());
    /// A response the middleware writes itself: `.{}` without a body,
    /// `.content_type` of a body it writes, or `.json`, the type of a JSON
    /// one.
    pub const Response = struct { description: ?[]const u8 = null, content_type: ?[]const u8 = null, json: type = void };

    const status_names = @typeInfo(std.http.Status).@"enum".field_names;

    fn noMiddlewareResponses() [status_names.len]std.lang.Type.Struct.FieldAttributes {
        const none: ?Response = null;
        return @splat(.{ .default_value_ptr = &none });
    }
};

/// What a document says besides the server: `zefir.openapi.document(...,
/// .{ .info = .{ .title = "Todos API", .version = "1.0.0" } })`.
///
/// - `.info`: its title and version, required, and the rest of its
///   `info`;
/// - `.version`: OpenAPI 3.1.2, or 3.2.1 with `.@"3.2"`, whose streams of
///   server-sent events have a schema;
/// - `.include` or `.exclude`: the controllers of the document, by type,
///   instead of all of them: `.exclude = &.{HealthController}`;
/// - `.prefix`: the server's `.prefix`, the same value as in its
///   `http.Server.Options`, which the document puts in `servers`; null,
///   for a prefix that comes from the config, leaves `servers` to `Docs`,
///   which puts the prefix of its own route there as it serves the
///   document;
/// - `.unknown_fields`: the server's `.unknown_fields`, the same value as
///   in its `http.Server.Options`: whether a body may hold keys its DTO
///   does not know decides its schema;
/// - `.servers`: the document's servers, instead of the server's prefix.
///
/// The settings of a server are values of the program that runs, so the
/// document cannot read them from the type of the parts: the application
/// gives the same values to both.
pub const DocumentOptions = struct {
    info: Info,
    version: Version = .@"3.1",
    include: []const type = &.{},
    exclude: []const type = &.{},
    prefix: ?[]const u8 = null,
    unknown_fields: http.Server.UnknownFieldsOptions = .{},
    servers: []const Server = &.{},

    pub const Info = struct { title: []const u8, version: []const u8, description: ?[]const u8 = null, contact: ?Contact = null, license: ?License = null };
    pub const Contact = struct { name: ?[]const u8 = null, url: ?[]const u8 = null, email: ?[]const u8 = null };
    pub const License = struct { name: []const u8, identifier: ?[]const u8 = null, url: ?[]const u8 = null };
    pub const Server = struct { url: []const u8, description: ?[]const u8 = null };
    pub const Version = enum { @"3.1", @"3.2" };
};

/// Whether values of `T`, inside optionals, write themselves with a
/// `jsonStringify` of their own, as `std.json.Value` does.
pub fn writesItself(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| writesItself(o.child),
        .@"struct", .@"union", .@"enum" => std.meta.hasFn(T, "jsonStringify"),
        else => false,
    };
}

/// The `FieldDoc` of each field. Its own quota: the compiler evaluates the
/// declaration of `Fields` with the default one, whoever names `Doc(T)`.
fn fieldDocTypes(comptime types: []const type) [types.len]type {
    @setEvalBranchQuota(1_000 + 100 * types.len);
    var out: [types.len]type = undefined;
    for (types, &out) |F, *Doc_| Doc_.* = FieldDoc(F);
    return out;
}

/// The attributes of the fields of `Fields`: the default of each is its
/// `FieldDoc` with nothing in it, `.{}`.
fn noDocs(comptime types: []const type) [types.len]std.lang.Type.Struct.FieldAttributes {
    @setEvalBranchQuota(1_000 + 100 * types.len);
    var out: [types.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (types, &out) |F, *attrs| {
        const empty: FieldDoc(F) = .{};
        attrs.* = .{ .default_value_ptr = &empty };
    }
    return out;
}

fn noResponses(comptime n: usize) [n]std.lang.Type.Struct.FieldAttributes {
    const none: ?ResponseDoc = null;
    return @splat(.{ .default_value_ptr = &none });
}

/// The methods of the routes of the controller `C`, in their order.
fn methodNames(comptime C: type) []const [:0]const u8 {
    if (!@hasDecl(C, "http_routes") or @TypeOf(C.http_routes) != type or !@hasDecl(C.http_routes, "methods"))
        @compileError("zefir.openapi: ControllerDoc(" ++ @typeName(C) ++ ") describes the routes of a controller: " ++ @typeName(C) ++ " has no pub const http_routes = http.routes(.{ ... })");
    return @typeInfo(@TypeOf(C.http_routes.methods)).@"struct".field_names;
}

/// The `RouteDoc` of each method, with a quota of their number, as
/// `fieldDocTypes` has.
fn routeDocTypes(comptime C: type) [methodNames(C).len]type {
    const names = methodNames(C);
    @setEvalBranchQuota(1_000 + 100 * names.len);
    var out: [names.len]type = undefined;
    for (names, &out) |name, *R| R.* = RouteDoc(C, name);
    return out;
}

/// The names of the statuses of the route `method` of `C`, as
/// `std.http.Status` names them: those of its `.responses`, else `ok` for a
/// stream and for a handler that returns `http.Json(T)`, `no_content` for
/// one of `!void`.
fn statusNames(comptime C: type, comptime method: []const u8) []const [:0]const u8 {
    const R = @field(C.http_routes.methods, method);
    if (R.responses.len > 0) {
        var out: [R.responses.len][:0]const u8 = undefined;
        for (R.responses, &out) |r, *name| name.* = @tagName(r.status);
        const final = out;
        return &final;
    }
    if (R.route_kind == .sse or !@hasDecl(C, method)) return &.{"ok"};
    const Return = @typeInfo(@TypeOf(@field(C, method))).@"fn".return_type.?;
    const Payload = if (@typeInfo(Return) == .error_union) @typeInfo(Return).error_union.payload else Return;
    return if (Payload == void) &.{"no_content"} else &.{"ok"};
}

const testing = std.testing;

// Application code of the tests: zefir ships no DTO, controller or
// middleware.
const Priority = enum { low, normal, high };
const Shape = union(enum) { circle: u32, none };
const Todo = struct {
    id: u64,
    title: []const u8,
    priority: Priority = .normal,
    comptime version: u32 = 1,
};
/// A type that writes itself, as a string.
const Money = struct {
    cents: u64,
    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}.{d:0>2}\"", .{ self.cents / 100, self.cents % 100 });
    }
};

test "Doc: a struct's texts, examples and a field doc for each field" {
    const D = Doc(Todo);
    const doc: D = .{
        .description = "A todo.",
        .example = .{ .id = 1, .title = "Buy milk" },
        .examples = &.{.{ .name = "urgent", .value = .{ .id = 2, .title = "Call back", .priority = .high } }},
        .fields = .{ .title = .{ .description = "What to do.", .example = "Buy milk" } },
    };
    try testing.expectEqualStrings("Buy milk", doc.example.?.title);
    try testing.expectEqualStrings("urgent", doc.examples[0].name);
    // A field doc for every field, the comptime one too; .{} for those left out.
    inline for (.{ "id", "title", "priority", "version" }) |name| try testing.expect(@hasField(D.Fields, name));
    try testing.expect(@FieldType(D.Fields, "id") == FieldDoc(u64));
    try testing.expectEqual(null, doc.fields.id.description);
    try testing.expectEqualStrings("What to do.", doc.fields.title.description.?);
    try testing.expect(!doc.deprecated and doc.name == null);
}

/// A struct of `n` fields of u8, `f0` and on: a type of many fields of an
/// application.
fn Wide(comptime n: usize) type {
    @setEvalBranchQuota(10_000 + 1_000 * n);
    var names: [n][:0]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("f{d}", .{i});
    const types: [n]type = @splat(u8);
    const attrs: [n]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, &names, &types, &attrs);
}

test "Doc: a type of many fields has a field doc for each, without a quota of the application's own" {
    const D = Doc(Wide(200));
    try testing.expectEqual(200, @typeInfo(D.Fields).@"struct".field_names.len);
    const doc: D = .{ .fields = .{ .f199 = .{ .description = "The last." } } };
    try testing.expectEqualStrings("The last.", doc.fields.f199.description.?);
    try testing.expectEqual(null, doc.fields.f0.description);
}

test "Doc: a union's fields are its variants; an enum has none; a type that writes itself has .as" {
    try testing.expect(@FieldType(Doc(Shape).Fields, "circle") == FieldDoc(u32));
    try testing.expect(@FieldType(Doc(Shape).Fields, "none") == FieldDoc(void));
    try testing.expect(!@hasField(Doc(Priority), "fields") and @hasField(Doc(Priority), "example"));
    const money: Doc(Money) = .{ .description = "An amount of money.", .as = []const u8 };
    try testing.expect(money.as == []const u8);
    try testing.expect(!@hasField(Doc(Money), "example") and !@hasField(Doc(Money), "fields"));
    // A field of such a type has no examples either.
    try testing.expect(!@hasField(FieldDoc(?Money), "example") and @hasField(FieldDoc(?Money), "description"));
    try testing.expect(@FieldType(FieldDoc(?u8), "example") == ??u8);
}

/// A controller with a route of each kind of default status, and one with
/// its own statuses.
const TodosV1Controller = struct {
    const Create = http.post("", .{ .responses = .{ .created = .{}, .ok = .{} } });

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{
            .list = http.get("", .{}),
            .create = Create,
            .delete = http.delete("/{id}", .{}),
            .events = http.sse.get("/events", .{ .events = union(enum) { changed: void } }),
        },
    });

    pub const openapi: ControllerDoc(@This()) = .{
        .tag = "Todos",
        .routes = .{
            .list = .{ .summary = "List todos" },
            .create = .{ .summary = "Create a todo", .responses = .{ .ok = .{ .description = "The todo made the first time." } } },
            .delete = .{ .summary = "Delete a todo" },
            .events = .{ .summary = "Live updates" },
        },
    };

    pub fn list(_: *TodosV1Controller, _: *http.Context) !http.Json(Todo) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" } };
    }
    pub fn create(_: *TodosV1Controller, _: *http.Context) !http.Json(Todo) {
        return .{ .value = .{ .id = 1, .title = "Buy milk" }, .status = 201 };
    }
    pub fn delete(_: *TodosV1Controller, _: *http.Context) !void {}
    pub fn events(_: *TodosV1Controller, _: *http.sse.Context) !void {}
};

test "ControllerDoc: an entry for each method, with the statuses of its route" {
    const doc = TodosV1Controller.openapi;
    try testing.expectEqualStrings("Todos", doc.tag.?);
    try testing.expectEqualStrings("Create a todo", doc.routes.create.summary);
    const R = ControllerDoc(TodosV1Controller).Routes;
    try testing.expectEqual(4, @typeInfo(R).@"struct".field_names.len);
    inline for (.{ "list", "create", "delete", "events" }) |name| try testing.expect(@FieldType(@FieldType(R, name), "summary") == []const u8);
    // The statuses of .responses, in their order.
    const create = @typeInfo(@FieldType(R, "create").Responses).@"struct".field_names;
    try testing.expectEqual(2, create.len);
    try testing.expectEqualStrings("created", create[0]);
    try testing.expectEqualStrings("ok", create[1]);
    try testing.expectEqualStrings("The todo made the first time.", doc.routes.create.responses.ok.?.description);
    try testing.expectEqual(null, doc.routes.create.responses.created);
    // Else the default one: 200 of a JSON value and of a stream, 204 of !void.
    inline for (.{ .{ "list", "ok" }, .{ "events", "ok" }, .{ "delete", "no_content" } }) |c| {
        const names = @typeInfo(RouteDoc(TodosV1Controller, c[0]).Responses).@"struct".field_names;
        try testing.expectEqual(1, names.len);
        try testing.expectEqualStrings(c[1], names[0]);
    }
}

test "MiddlewareDoc: security, input and a response for each status" {
    const doc: MiddlewareDoc = .{
        .security_schemes = &.{
            .{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "opaque" } } },
            .{ .name = "session", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } },
            .{ .name = "mtls", .kind = .mutual_tls },
        },
        .security = .any,
        .roles = &.{"todos"},
        .headers = struct { authorization: ?[]const u8 = null },
        .responses = .{ .not_modified = .{}, .unauthorized = .{ .content_type = "text/html" } },
    };
    try testing.expectEqual(3, doc.security_schemes.len);
    try testing.expect(doc.query == void and doc.cookies == void and doc.headers != void);
    try testing.expectEqualStrings("text/html", doc.responses.unauthorized.?.content_type.?);
    try testing.expect(doc.responses.not_modified.?.json == void);
    try testing.expectEqual(null, doc.responses.ok);
    try testing.expectEqual(@typeInfo(std.http.Status).@"enum".field_names.len, @typeInfo(MiddlewareDoc.Responses).@"struct".field_names.len);
}

test "DocumentOptions: the info is required; 3.1 by default" {
    const opts: DocumentOptions = .{ .info = .{ .title = "Todos API", .version = "1.0.0" }, .exclude = &.{TodosV1Controller} };
    try testing.expectEqual(DocumentOptions.Version.@"3.1", opts.version);
    try testing.expectEqual(0, opts.servers.len);
    try testing.expect(opts.exclude[0] == TodosV1Controller);
}

// The Debug check of zefir-http reads a real `MiddlewareDoc` by the names
// of its fields, on a controller whose `openapi` is a real `ControllerDoc`.

const PageQuery = struct { limit: u32 = 20 };
const OtherQuery = struct { q: ?[]const u8 = null };
const Item = struct { id: u64 };

/// Reads a page of its own, and answers 304 itself when asked.
const Paging = struct {
    pub const openapi: MiddlewareDoc = .{
        .query = PageQuery,
        .responses = .{ .not_modified = .{ .description = "Nothing changed since the ETag." } },
    };

    pub fn run(ctx: *http.Context) !http.MiddlewareResult {
        _ = try ctx.query(PageQuery);
        if (ctx.request.header("if-none-match") != null) {
            _ = ctx.response.status(304);
            return .handled;
        }
        return .next;
    }
};

const ItemsController = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/items",
        .methods = .{ .list = http.get("", .{ .middleware = .{Paging} }) },
    });

    pub const openapi: ControllerDoc(@This()) = .{ .routes = .{ .list = .{ .summary = "List items" } } };

    pub fn list(_: *ItemsController, ctx: *http.Context) !http.Json(Item) {
        // A query that nobody declares.
        if (ctx.request.header("x-other") != null) _ = try ctx.query(OtherQuery);
        return .{ .value = .{ .id = 1 } };
    }
};

fn expectStatus(backend: *http.testing.Backend, target: []const u8, headers: []const [2][]const u8, status: u16) !void {
    var res = try backend.request(testing.io, .{ .method = .GET, .target = target, .headers = headers });
    defer res.deinit();
    try testing.expectEqual(status, res.status);
}

test "the Debug check of zefir-http reads a typed MiddlewareDoc on a controller with a ControllerDoc" {
    if (@import("builtin").mode != .debug) return error.SkipZigTest;
    var items: ItemsController = .{};
    var backend: http.testing.Backend = .init(testing.allocator);
    defer backend.deinit();
    var server: http.Server = try .init(testing.allocator, .{ .controllers = .{&items} }, .{ .listen = .{ .backend = backend.backend() } });
    defer server.deinit(testing.io);
    try server.start(testing.io);
    const level = testing.log_level;
    testing.log_level = .err; // the lines of the check are warnings
    defer testing.log_level = level;

    // The query and the 304 that the middleware declares pass.
    try expectStatus(&backend, "/items?limit=5", &.{}, 200);
    try expectStatus(&backend, "/items", &.{.{ "if-none-match", "\"v1\"" }}, 304);
    // The check is on: a query nobody declares is the server's 500.
    try expectStatus(&backend, "/items", &.{.{ "x-other", "1" }}, 500);
}

test {
    std.testing.refAllDecls(@This());
}
