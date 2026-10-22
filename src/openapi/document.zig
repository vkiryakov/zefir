//! The document of a server, which the compiler builds:
//! `zefir.openapi.document(@TypeOf(parts), .{ .info = ... })` reads what
//! `http.describe` tells of the server that `http.Server.init` builds from
//! parts of that type, and gives the tree of its OpenAPI document, every
//! check done. The program writes the tree once, when it runs: `Docs`
//! serves those bytes, and `openapi.testing.expectFile` compares them with
//! the file in the repository.
//!
//! Each route of the controllers of the document is an operation:
//! - its `operationId` (`TodosV1.create`) and its tag, from the name of its
//!   controller (`Crud_Todo` for a generic, `CrudController(dto.Todo)`) and
//!   its `ControllerDoc`, with the texts there;
//! - its `security`, from the `MiddlewareDoc` of the middleware of its
//!   chain;
//! - its parameters: the fields of its `.path`, `.query`, `.headers` and
//!   `.cookies`, then those of the middleware of its chain;
//! - its `requestBody`, of its `.body` or its `.form`;
//! - its responses: those of its `.responses`, else its default one; those
//!   the middleware of its chain write themselves; and those of its
//!   errors, as the error handler's `mapError` answers each, with the body
//!   it gives as an example. 204, 205 and 304 have no content, whatever
//!   the handler, a middleware or `mapError` gives them: zefir-http sends
//!   none.
//!
//! The document holds the controllers of `.controllers`, all of them, those
//! of `.include`, or all but those of `.exclude`; never a `Docs`, the
//! static files, the HEAD the server answers on the path of a GET route or
//! its automatic OPTIONS. The order of everything is fixed, so that the
//! same program gives the same bytes: paths and operations in the order of
//! `.controllers` and their `.methods`, statuses by number, the examples of
//! errors by the names of the errors, schemas and security schemes by
//! name.
const std = @import("std");
const http = @import("http");
const json = @import("json.zig");
const schema = @import("schema.zig");
const example = @import("example.zig");
const declarations = @import("openapi.zig");

const DocumentOptions = declarations.DocumentOptions;
const MiddlewareDoc = declarations.MiddlewareDoc;
const Node = json.Node;
const Member = json.Member;
const Writer = std.Io.Writer;

/// The OpenAPI document of a server, as `document` builds it: its tree,
/// written when the program runs.
pub const Document = struct {
    /// The tree of the document.
    root: Node,
    /// The document was built without `.prefix` and `.servers`, as for a
    /// prefix that comes from the config when the program runs: it has no
    /// `servers`, and `Docs` puts the prefix of its own route there when it
    /// serves the document.
    runtime_prefix: bool = false,
    /// The `.prefix` it was built with; null for none. In Debug, `Docs`
    /// answers 500 on a route whose prefix is another.
    prefix: ?[]const u8 = null,

    /// Writes the document: JSON with an indent of two spaces, a member or
    /// an item per line, a newline at the end. These are the bytes of
    /// `openapi.json`.
    pub fn write(d: Document, w: *Writer) Writer.Error!void {
        return json.write(d.root, w);
    }
};

/// The document of the server that `http.Server.init` builds from parts
/// of type `Parts`, as `opts` describes it. Call it at compile time, in
/// the function that builds the server, with the type of the same parts;
/// the settings of the server that the document needs, its prefix and its
/// `.unknown_fields`, it gets in `opts`:
///
/// ```zig
/// const parts = .{ .controllers = .{ &s.todos, &s.docs } };
/// s.docs = try .init(gpa, comptime zefir.openapi.document(@TypeOf(parts), .{
///     .info = .{ .title = "Todos API", .version = "1.0.0" },
///     .prefix = "/api",
/// }));
/// s.server = try .init(gpa, parts, .{ .listen = .{ .backend = backend }, .prefix = "/api" });
/// ```
///
/// It raises its own eval branch quota by its work: the application sets
/// none.
pub fn document(comptime Parts: type, comptime opts: DocumentOptions) Document {
    comptime {
        const d = http.describe(Parts);
        @setEvalBranchQuota(quotaOf(d.routes.len));
        const routes = documented(d, opts);
        var registry: schema.Registry = .init(opts.unknown_fields.body);
        for (routes) |r| use(&registry, d, r);
        registry.finish();
        const reg = registry;
        var members: []const Member = &.{
            .{ .key = "openapi", .value = .{ .string = switch (opts.version) {
                .@"3.1" => "3.1.2",
                .@"3.2" => "3.2.1",
            } } },
            .{ .key = "info", .value = infoNode(opts.info) },
        };
        if (serversNode(opts.prefix, opts.servers)) |servers| members = members ++ [_]Member{.{ .key = "servers", .value = servers }};
        const tags = tagsNode(routes);
        if (tags.array.len > 0) members = members ++ [_]Member{.{ .key = "tags", .value = tags }};
        members = members ++ [_]Member{.{ .key = "paths", .value = pathsNode(&reg, d, routes, opts.version) }};
        if (componentsNode(&reg, routes)) |components| members = members ++ [_]Member{.{ .key = "components", .value = components }};
        return .{ .root = .{ .object = members }, .runtime_prefix = opts.prefix == null and opts.servers.len == 0, .prefix = opts.prefix };
    }
}

/// The eval branch quota of a document of `routes` routes: the schemas,
/// the rules and the examples of each, its parameters and responses.
fn quotaOf(comptime routes: usize) u32 {
    return @intCast(@min(std.math.maxInt(u32), 10_000_000 + 100_000 * routes));
}

/// Stops the build with a message of zefir-openapi.
fn fail(comptime text: []const u8) noreturn {
    @compileError("zefir.openapi: " ++ text);
}

// ------------------------------------------------------------------ the routes of the document

/// The routes of the controllers of the document, in the server's order.
fn documented(comptime d: http.Description, comptime opts: DocumentOptions) []const http.RouteDescription {
    if (opts.include.len > 0 and opts.exclude.len > 0)
        fail(".include and .exclude together; a document takes the controllers of .include, or all but those of .exclude");
    for (opts.include) |C| expectController(d, C, ".include");
    for (opts.exclude) |C| expectController(d, C, ".exclude");
    var out: []const http.RouteDescription = &.{};
    for (d.routes) |r| {
        // A controller of documentation is never in a document.
        if (@hasDecl(r.Controller, "zefir_openapi_docs")) continue;
        if (opts.include.len > 0 and !containsType(opts.include, r.Controller)) continue;
        if (containsType(opts.exclude, r.Controller)) continue;
        checkController(r.Controller, r.controller_name, opts.include.len > 0);
        out = out ++ [_]http.RouteDescription{r};
    }
    return out;
}

/// `C`, named in `list`, is a controller of the server.
fn expectController(comptime d: http.Description, comptime C: type, comptime list: []const u8) void {
    for (d.routes) |r| {
        if (r.Controller == C) return;
    }
    fail(list ++ " names " ++ schema.typeName(C) ++ ", which is not a controller of the server; name the types of controllers of .controllers");
}

/// The controller `C` of the document has its texts, a `ControllerDoc`.
fn checkController(comptime C: type, comptime name: []const u8, comptime included: bool) void {
    if (!@hasDecl(C, "openapi"))
        fail(name ++ " has no pub const openapi: zefir.openapi.ControllerDoc(" ++ name ++ "); add one, or leave it out " ++
            (if (included) "of .include" else "with .exclude = &.{" ++ name ++ "}"));
    if (@TypeOf(C.openapi) != declarations.ControllerDoc(C))
        fail(name ++ ".openapi must be of type zefir.openapi.ControllerDoc(" ++ name ++ ")");
}

/// The `MiddlewareDoc` of an element of a chain, null without one.
fn middlewareDoc(comptime e: http.ChainElement) ?MiddlewareDoc {
    if (!@hasDecl(e.Impl, "openapi")) return null;
    if (@TypeOf(e.Impl.openapi) != MiddlewareDoc)
        fail("the openapi of the middleware " ++ e.name ++ " must be of type zefir.openapi.MiddlewareDoc");
    return e.Impl.openapi;
}

/// Records the types of the bodies of the route `r` in `reg`: what it
/// reads, what it answers with, and the body of the answers to its errors.
fn use(comptime reg: *schema.Registry, comptime d: http.Description, comptime r: http.RouteDescription) void {
    const R = r.Route;
    if (R.Body != void) reg.use(.{ .T = R.Body, .direction = .input });
    if (R.Form != void) reg.use(.{ .T = R.Form, .direction = .input });
    if (r.kind == .sse) {
        const events = @typeInfo(R.Events).@"union".field_types;
        if (events.len == 0)
            fail(where(r) ++ ": .events = " ++ schema.typeName(R.Events) ++ " has no variants, so the stream has no events to show; give it a variant for each event");
        for (events) |P| {
            if (P != void) reg.use(.{ .T = P, .direction = .output });
        }
    } else if (R.responses.len == 0) {
        if (r.Value != void) reg.use(.{ .T = r.Value, .direction = .output });
    } else for (R.responses) |res| {
        const status = @backingInt(res.status);
        if (bodiless(status)) continue;
        if (res.json != void) {
            reg.use(.{ .T = res.json, .direction = .output });
        } else if (res.content_type == null and r.Value != void and success(status)) {
            reg.use(.{ .T = r.Value, .direction = .output });
        }
    }
    for (r.chain) |e| {
        const doc = middlewareDoc(e) orelse continue;
        for (middlewareResponses(doc)) |m| {
            if (m.json != void and !bodiless(m.status)) reg.use(.{ .T = m.json, .direction = .output });
        }
    }
    for (errorStatuses(d.ErrorHandler, r.Errors, where(r))) |e| {
        if (bodiless(e.status)) continue;
        reg.use(errorUse(d));
        break;
    }
}

/// The use of the body of the answers to errors.
fn errorUse(comptime d: http.Description) schema.Use {
    return .{ .T = d.ErrorBody, .direction = .output, .problem = d.ErrorBody == http.Problem };
}

/// How messages name a route: `TodosV1Controller.create`.
fn where(comptime r: http.RouteDescription) []const u8 {
    return r.controller_name ++ "." ++ r.handler;
}

// ------------------------------------------------------------------ info, servers, tags

fn infoNode(comptime info: DocumentOptions.Info) Node {
    var m: []const Member = &.{ string("title", info.title), string("version", info.version) };
    if (info.description) |text| m = m ++ [_]Member{string("description", text)};
    if (info.contact) |c| {
        var contact: []const Member = &.{};
        if (c.name) |text| contact = contact ++ [_]Member{string("name", text)};
        if (c.url) |text| contact = contact ++ [_]Member{string("url", text)};
        if (c.email) |text| contact = contact ++ [_]Member{string("email", text)};
        m = m ++ [_]Member{.{ .key = "contact", .value = .{ .object = contact } }};
    }
    if (info.license) |l| {
        if (l.identifier != null and l.url != null)
            fail(".info.license has both .identifier and .url; OpenAPI takes one of them: the SPDX identifier, or the URL of the license");
        var license: []const Member = &.{string("name", l.name)};
        if (l.identifier) |text| license = license ++ [_]Member{string("identifier", text)};
        if (l.url) |text| license = license ++ [_]Member{string("url", text)};
        m = m ++ [_]Member{.{ .key = "license", .value = .{ .object = license } }};
    }
    return .{ .object = m };
}

/// `.servers` of the options, else the server's prefix when it is known
/// and not empty; null for none: an empty prefix, or one that comes at run
/// time.
fn serversNode(comptime prefix: ?[]const u8, comptime servers: []const DocumentOptions.Server) ?Node {
    if (servers.len > 0) {
        var out: [servers.len]Node = undefined;
        for (servers, &out) |s, *item| {
            var m: []const Member = &.{string("url", s.url)};
            if (s.description) |text| m = m ++ [_]Member{string("description", text)};
            item.* = .{ .object = m };
        }
        const final = out;
        return .{ .array = &final };
    }
    const known = prefix orelse return null;
    if (known.len == 0) return null;
    return .{ .array = &.{json.object(&.{string("url", known)})} };
}

/// The tags of the controllers, in the order they first come.
fn tagsNode(comptime routes: []const http.RouteDescription) Node {
    const Tag = struct { name: []const u8, description: ?[]const u8, by: []const u8 };
    var tags: []const Tag = &.{};
    var seen: []const type = &.{};
    for (routes) |r| {
        if (containsType(seen, r.Controller)) continue;
        seen = seen ++ [_]type{r.Controller};
        const doc = r.Controller.openapi;
        const name = tagOf(r);
        for (tags, 0..) |t, i| {
            if (!std.mem.eql(u8, t.name, name)) continue;
            const text = doc.description orelse break;
            if (t.description) |other| {
                if (!std.mem.eql(u8, other, text))
                    fail("the tag " ++ name ++ " has two descriptions, of " ++ t.by ++ " and of " ++ r.controller_name ++ "; describe it in one of them");
                break;
            }
            var next = tags[0..tags.len].*;
            next[i] = .{ .name = name, .description = text, .by = r.controller_name };
            const final = next;
            tags = &final;
            break;
        } else tags = tags ++ [_]Tag{.{ .name = name, .description = doc.description, .by = r.controller_name }};
    }
    var out: [tags.len]Node = undefined;
    for (tags, &out) |t, *item| {
        var m: []const Member = &.{string("name", t.name)};
        if (t.description) |text| m = m ++ [_]Member{string("description", text)};
        item.* = .{ .object = m };
    }
    const final = out;
    return .{ .array = &final };
}

/// The tag of the operations of the controller of `r`: its `.tag`, else
/// its name in the document.
fn tagOf(comptime r: http.RouteDescription) []const u8 {
    if (r.Controller.openapi.tag) |tag| return tag;
    return documentName(r) orelse
        fail(messageName(r) ++ " is a controller of an anonymous type, whose name changes as the program does; give it a tag: .tag = \"...\" in its ControllerDoc");
}

/// The name of the controller of `r` in its default tag and operationIds:
/// without `Controller` at its end, and a generic's arguments after it as
/// the names of schemas have them: `TodosV1Controller` is `TodosV1`,
/// `CrudController(dto.Todo)` is `Crud_Todo`. Null for a controller of an
/// anonymous type, whose name holds the number the compiler gives it.
fn documentName(comptime r: http.RouteDescription) ?[]const u8 {
    const name = r.controller_name;
    const flat = if (std.mem.findScalar(u8, name, '(')) |open| schema.schemaName(bareName(name[0..open]) ++ name[open..]) else bareName(name);
    return if (schema.hasCompilerNumber(flat)) null else flat;
}

/// How messages name the controller of `r`: a generic without its
/// arguments, `Crud(...)`.
fn messageName(comptime r: http.RouteDescription) []const u8 {
    const name = r.controller_name;
    const open = std.mem.findScalar(u8, name, '(') orelse return name;
    return name[0..open] ++ "(...)";
}

/// The name of a controller without `Controller` at its end:
/// `TodosV1Controller` is `TodosV1`.
fn bareName(comptime name: []const u8) []const u8 {
    const suffix = "Controller";
    if (name.len > suffix.len and std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    return name;
}

// ------------------------------------------------------------------ paths and operations

/// The paths, each with its operations, in the order of the routes; two
/// operations of one `operationId` stop the build.
fn pathsNode(comptime reg: *const schema.Registry, comptime d: http.Description, comptime routes: []const http.RouteDescription, comptime version: DocumentOptions.Version) Node {
    const Path = struct { key: []const u8, operations: []const Member };
    var paths: []const Path = &.{};
    const Id = struct { id: []const u8, where: []const u8 };
    var ids: [routes.len]Id = undefined;
    for (routes, &ids) |r, *id| {
        id.* = .{ .id = operationId(r), .where = where(r) };
        const key = pathKey(r.template);
        const op: Member = .{ .key = methodKey(r.method), .value = operationNode(reg, d, r, version) };
        for (paths, 0..) |p, i| {
            if (!std.mem.eql(u8, p.key, key)) continue;
            var next = paths[0..paths.len].*;
            next[i].operations = p.operations ++ [_]Member{op};
            const final = next;
            paths = &final;
            break;
        } else paths = paths ++ [_]Path{.{ .key = key, .operations = &.{op} }};
    }
    const by_id = sorted(Id, &ids, struct {
        fn less(a: Id, b: Id) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);
    for (by_id[0..by_id.len -| 1], by_id[@min(1, by_id.len)..]) |a, b| {
        if (std.mem.eql(u8, a.id, b.id))
            fail(a.where ++ " and " ++ b.where ++ " have one operationId, " ++ a.id ++ "; give one of them another with .operation_id in the routes of its ControllerDoc");
    }
    var out: [paths.len]Member = undefined;
    for (paths, &out) |p, *m| m.* = .{ .key = p.key, .value = .{ .object = p.operations } };
    const final = out;
    return .{ .object = &final };
}

/// The key of a path: the template, `{*rest}` as `{rest}`; "/" for the
/// root.
fn pathKey(comptime template: []const u8) []const u8 {
    if (template.len == 0) return "/";
    var out: []const u8 = "";
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '{' and i + 1 < template.len and template[i + 1] == '*') {
            out = out ++ "{";
            i += 1;
        } else out = out ++ template[i .. i + 1];
    }
    return out;
}

/// `get`, `post`, ...: the method as OpenAPI names it.
fn methodKey(comptime method: std.http.Method) []const u8 {
    const name = @tagName(method);
    var out: [name.len]u8 = undefined;
    for (name, &out) |c, *lower| lower.* = std.ascii.toLower(c);
    const final = out;
    return &final;
}

/// The `operationId` of `r`: its `.operation_id`, else the name of its
/// controller in the document and its method, `TodosV1.create`.
fn operationId(comptime r: http.RouteDescription) []const u8 {
    const doc = @field(r.Controller.openapi.routes, r.handler);
    if (doc.operation_id) |id| return id;
    const name = documentName(r) orelse fail(messageName(r) ++ "." ++ r.handler ++ ": its controller is of an anonymous type, whose name changes as the program does; " ++
        "give the route an operationId: .operation_id = \"...\" in the routes of its ControllerDoc");
    return name ++ "." ++ r.handler;
}

/// The operation of the route `r`.
fn operationNode(comptime reg: *const schema.Registry, comptime d: http.Description, comptime r: http.RouteDescription, comptime version: DocumentOptions.Version) Node {
    const doc = @field(r.Controller.openapi.routes, r.handler);
    var m: []const Member = &.{
        string("operationId", operationId(r)),
        .{ .key = "tags", .value = .{ .array = &.{.{ .string = tagOf(r) }} } },
        string("summary", doc.summary),
    };
    const params = parametersOf(r);
    var description: []const []const u8 = if (doc.description) |text| &.{text} else &.{};
    if (params.self_checked) description = description ++ [_][]const u8{"The server also checks how these parameters fit together."};
    if (description.len > 0) m = m ++ [_]Member{string("description", joined(description))};
    if (doc.deprecated) m = m ++ [_]Member{.{ .key = "deprecated", .value = .{ .boolean = true } }};
    if (securityNode(r)) |security| m = m ++ [_]Member{.{ .key = "security", .value = security }};
    if (params.list.len > 0) m = m ++ [_]Member{.{ .key = "parameters", .value = .{ .array = params.list } }};
    if (requestBodyNode(reg, r.Route)) |body| m = m ++ [_]Member{.{ .key = "requestBody", .value = body }};
    m = m ++ [_]Member{.{ .key = "responses", .value = responsesNode(answersOf(reg, d, r, version), where(r)) }};
    return .{ .object = m };
}

// ------------------------------------------------------------------ parameters

/// The parameters of a route, and whether a DTO of them checks its fields
/// against each other with `validateSelf`, which the parameters cannot
/// say.
const Parameters = struct { list: []const Node, self_checked: bool };

/// A parameter in the making: where it is, and what declares it, for
/// messages.
const Param = struct { name: []const u8, in: []const u8, node: Node, from: []const u8 };

/// The parameters of `r`: of its path, its `.query`, `.headers` and
/// `.cookies`, then of the DTOs the middleware of its chain read. Two of
/// one name in one place stop the build.
fn parametersOf(comptime r: http.RouteDescription) Parameters {
    const R = r.Route;
    var list: []const Param = &.{};
    var self_checked = false;
    // The path, in the order of the template.
    for (r.params, 0..) |name, i| {
        const rest_note: ?[]const u8 = if (r.catch_all and i == r.params.len - 1) "The rest of the path, which may hold '/'." else null;
        if (R.Path == void) {
            var m: []const Member = &.{ string("name", name), string("in", "path"), .{ .key = "required", .value = .{ .boolean = true } } };
            if (rest_note) |note| m = m ++ [_]Member{string("description", note)};
            m = m ++ [_]Member{.{ .key = "schema", .value = json.object(&.{string("type", "string")}) }};
            list = list ++ [_]Param{.{ .name = name, .in = "path", .node = .{ .object = m }, .from = "the path" }};
        } else {
            const field = pathField(R.Path, name);
            const node = parameterNode(name, "path", true, schema.parameter(R.Path, field, .path), rest_note, null);
            list = list ++ [_]Param{.{ .name = name, .in = "path", .node = node, .from = ".path = " ++ schema.typeName(R.Path) }};
        }
    }
    if (R.Path != void and @hasDecl(R.Path, "validateSelf")) self_checked = true;
    const sources = [_]struct { schema.Source, type }{ .{ .query, R.Query }, .{ .headers, R.Headers }, .{ .cookies, R.Cookies } };
    var taken: []const type = &.{};
    for (sources) |s| {
        if (s[1] == void) continue;
        list = list ++ dtoParams(s[1], s[0], "." ++ @tagName(s[0]) ++ " = " ++ schema.typeName(s[1]));
        taken = taken ++ [_]type{s[1]};
        if (@hasDecl(s[1], "validateSelf")) self_checked = true;
    }
    // Those the middleware read; a DTO the route declares too is read once.
    for (r.chain) |e| {
        const doc = middlewareDoc(e) orelse continue;
        const read = [_]struct { schema.Source, type }{ .{ .query, doc.query }, .{ .headers, doc.headers }, .{ .cookies, doc.cookies } };
        for (read) |s| {
            if (s[1] == void or containsType(taken, s[1])) continue;
            list = list ++ dtoParams(s[1], s[0], "the middleware " ++ e.name ++ " (." ++ @tagName(s[0]) ++ " = " ++ schema.typeName(s[1]) ++ ")");
            taken = taken ++ [_]type{s[1]};
            if (@hasDecl(s[1], "validateSelf")) self_checked = true;
        }
    }
    for (list, 0..) |a, i| {
        for (list[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.in, b.in)) continue;
            // The names of headers are not case-sensitive.
            const same = if (std.mem.eql(u8, a.in, "header")) std.ascii.eqlIgnoreCase(a.name, b.name) else std.mem.eql(u8, a.name, b.name);
            if (same) fail(where(r) ++ ": two parameters " ++ a.name ++ " in the " ++ a.in ++ ", of " ++ a.from ++ " and of " ++ b.from ++ "; give one of them another name");
        }
    }
    var nodes: [list.len]Node = undefined;
    for (list, &nodes) |p, *n| n.* = p.node;
    const final = nodes;
    return .{ .list = &final, .self_checked = self_checked };
}

/// The parameters of the fields of a DTO of the query, the headers or the
/// cookies, `from` naming it in messages.
fn dtoParams(comptime Dto: type, comptime source: schema.Source, comptime from: []const u8) []const Param {
    const in = switch (source) {
        .path => "path",
        .query => "query",
        .headers => "header",
        .cookies => "cookie",
    };
    var out: []const Param = &.{};
    const info = @typeInfo(Dto).@"struct";
    for (info.field_names, info.field_types, info.field_attrs) |field, F, attrs| {
        if (attrs.@"comptime") continue;
        const name = if (source == .headers) http.Description.headerName(field) else example.outsideName(Dto, field);
        const required = @typeInfo(F) != .optional and attrs.default_value_ptr == null;
        const Value = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        const style: ?[]const u8 = if (schema.listItem(Value) == null) null else switch (source) {
            .headers => "simple",
            else => "form",
        };
        const node = parameterNode(name, in, required, schema.parameter(Dto, field, source), null, style);
        out = out ++ [_]Param{.{ .name = name, .in = in, .node = node, .from = from }};
    }
    return out;
}

/// The field of the path DTO `P` whose outside name is `param`.
fn pathField(comptime P: type, comptime param: []const u8) []const u8 {
    const info = @typeInfo(P).@"struct";
    for (info.field_names, info.field_attrs) |field, attrs| {
        if (attrs.@"comptime") continue;
        if (std.mem.eql(u8, example.outsideName(P, field), param)) return field;
    }
    unreachable; // zefir-http checks the path DTO against the template
}

/// A parameter: `name`, `in` and `required`, then what `schema.parameter`
/// gives of its field, `note` added to its description, and the `style` of
/// a list, `form` in the query and the cookies, `simple` in the headers.
fn parameterNode(comptime name: []const u8, comptime in: []const u8, comptime required: bool, comptime field: Node, comptime note: ?[]const u8, comptime style: ?[]const u8) Node {
    const given = field.object;
    var m: []const Member = &.{ string("name", name), string("in", in), .{ .key = "required", .value = .{ .boolean = required } } };
    var description: []const []const u8 = if (json.get(given, "description")) |text| &.{text.string} else &.{};
    if (note) |text| description = description ++ [_][]const u8{text};
    if (description.len > 0) m = m ++ [_]Member{string("description", joined(description))};
    if (json.get(given, "deprecated")) |flag| m = m ++ [_]Member{.{ .key = "deprecated", .value = flag }};
    if (style) |s| m = m ++ [_]Member{ string("style", s), .{ .key = "explode", .value = .{ .boolean = std.mem.eql(u8, s, "form") } } };
    if (json.get(given, "example")) |x| m = m ++ [_]Member{.{ .key = "example", .value = x }};
    m = m ++ [_]Member{.{ .key = "schema", .value = json.get(given, "schema").? }};
    return .{ .object = m };
}

// ------------------------------------------------------------------ the request body

/// The body of a route: `.body` as `application/json`, `.form` as
/// `application/x-www-form-urlencoded`; null without one.
fn requestBodyNode(comptime reg: *const schema.Registry, comptime R: type) ?Node {
    const T, const media = if (R.Body != void)
        .{ R.Body, "application/json" }
    else if (R.Form != void)
        .{ R.Form, "application/x-www-form-urlencoded" }
    else
        return null;
    var content: []const Member = &.{.{ .key = "schema", .value = reg.schema(.{ .T = T, .direction = .input }) }};
    const examples = namedExamples(T, .input);
    if (examples.len > 0) content = content ++ [_]Member{.{ .key = "examples", .value = .{ .object = examples } }};
    return json.object(&.{
        .{ .key = "required", .value = .{ .boolean = true } },
        .{ .key = "content", .value = json.object(&.{.{ .key = media, .value = .{ .object = content } }}) },
    });
}

/// The `.examples` of the `Doc(T)` of a body, by their names, as they go
/// `way`: those of a request or a response with that body.
fn namedExamples(comptime T: type, comptime way: example.Way) []const Member {
    const container = switch (@typeInfo(T)) {
        .@"struct" => |s| !s.is_tuple,
        .@"union" => |u| u.tag_type != null,
        .@"enum" => true,
        else => false,
    };
    if (!container or !schema.hasDoc(T)) return &.{};
    const doc = schema.docOf(T);
    if (!@hasField(@TypeOf(doc), "examples")) return &.{};
    var out: [doc.examples.len]Member = undefined;
    for (doc.examples, &out, 0..) |e, *m, i| {
        for (doc.examples[0..i]) |before| {
            if (std.mem.eql(u8, before.name, e.name))
                fail(schema.typeName(T) ++ ".openapi.examples has two examples named " ++ e.name ++ "; a request or a response shows them by their names");
        }
        var members: []const Member = &.{};
        if (e.summary) |text| members = members ++ [_]Member{string("summary", text)};
        members = members ++ [_]Member{.{ .key = "value", .value = example.value(T, e.value, way, std.fmt.comptimePrint("{s}.openapi.examples[{d}]", .{ schema.typeName(T), i })) }};
        m.* = .{ .key = e.name, .value = .{ .object = members } };
    }
    const final = out;
    return &final;
}

// ------------------------------------------------------------------ responses

/// A response of an operation as one place declares it: its status, its
/// description when the place gives one, and its body, or none.
const Answer = struct {
    status: u16,
    description: ?[]const u8 = null,
    /// The media type of its body, as declared; null without a body.
    media: ?[]const u8 = null,
    /// The schema of its body: two answers of one status and one media type
    /// must have the same.
    shape: Node = .null,
    /// `shape` is the schema of each event of a stream, `itemSchema`.
    items: bool = false,
    /// Named examples of its body.
    examples: []const Member = &.{},
    /// What declares it, for messages.
    from: []const u8,
};

/// The responses of `r`: its own, those of the middleware of its chain,
/// and the answers to its errors.
fn answersOf(comptime reg: *const schema.Registry, comptime d: http.Description, comptime r: http.RouteDescription, comptime version: DocumentOptions.Version) []const Answer {
    var out = routeAnswers(reg, r, version);
    for (r.chain) |e| {
        const doc = middlewareDoc(e) orelse continue;
        for (middlewareResponses(doc)) |m| {
            const from = "the middleware " ++ e.name;
            out = out ++ [_]Answer{if (bodiless(m.status))
                .{ .status = m.status, .description = m.description, .from = from }
            else if (m.content_type) |media|
                textAnswer(m.status, m.description, media, from)
            else if (m.json != void)
                jsonAnswer(reg, m.status, m.description, m.json, from)
            else
                .{ .status = m.status, .description = m.description, .from = from }};
        }
    }
    const media = if (d.ErrorBody == http.Problem) "application/problem+json" else "application/json";
    const from = "its errors, as " ++ schema.typeName(d.ErrorHandler) ++ ".mapError answers them";
    for (errorStatuses(d.ErrorHandler, r.Errors, where(r))) |e| {
        out = out ++ [_]Answer{if (bodiless(e.status))
            .{ .status = e.status, .from = from }
        else
            .{ .status = e.status, .media = media, .shape = reg.schema(errorUse(d)), .examples = e.examples, .from = from }};
    }
    return out;
}

/// The responses of the route itself: those of its `.responses`, else its
/// default one, with the descriptions of its `ControllerDoc`; 204, 205 and
/// 304 without content, the value of an `http.Json(T)` too. A stream also
/// answers 204, when its handler returns without `subscribe`, which tells
/// an EventSource to stop reconnecting.
fn routeAnswers(comptime reg: *const schema.Registry, comptime r: http.RouteDescription, comptime version: DocumentOptions.Version) []const Answer {
    const R = r.Route;
    const doc = @field(r.Controller.openapi.routes, r.handler);
    const from = ".responses of " ++ where(r);
    if (r.kind == .sse) return &.{ streamAnswer(reg, R.Events, routeText(doc, "ok"), version, from), .{ .status = 204, .from = from } };
    if (R.responses.len == 0) {
        if (r.Value == void) return &.{.{ .status = 204, .description = routeText(doc, "no_content"), .from = from }};
        return &.{jsonAnswer(reg, 200, routeText(doc, "ok"), r.Value, from)};
    }
    var out: [R.responses.len]Answer = undefined;
    for (R.responses, &out) |res, *answer| {
        const status = @backingInt(res.status);
        const text = routeText(doc, @tagName(res.status));
        answer.* = if (bodiless(status))
            .{ .status = status, .description = text, .from = from }
        else if (res.content_type) |media|
            textAnswer(status, text, media, from)
        else if (res.json != void)
            jsonAnswer(reg, status, text, res.json, from)
        else if (r.Value != void and success(status))
            jsonAnswer(reg, status, text, r.Value, from)
        else
            .{ .status = status, .description = text, .from = from };
    }
    const final = out;
    return &final;
}

/// The description that the `RouteDoc` of a route gives its status `name`.
fn routeText(comptime doc: anytype, comptime name: []const u8) ?[]const u8 {
    const given = @field(doc.responses, name) orelse return null;
    return given.description;
}

/// A JSON body of type `T`, with the `.examples` of its `Doc`.
fn jsonAnswer(comptime reg: *const schema.Registry, comptime status: u16, comptime description: ?[]const u8, comptime T: type, comptime from: []const u8) Answer {
    const body = reg.schema(.{ .T = T, .direction = .output });
    return .{ .status = status, .description = description, .media = "application/json", .shape = body, .examples = namedExamples(T, .output), .from = from };
}

/// A body of the media type `media` that a handler or a middleware writes
/// itself: a string.
fn textAnswer(comptime status: u16, comptime description: ?[]const u8, comptime media: []const u8, comptime from: []const u8) Answer {
    return .{ .status = status, .description = description, .media = media, .shape = json.object(&.{string("type", "string")}), .from = from };
}

/// The 200 of a stream of the events `E`. In 3.1 its body is a string, and
/// its description, after the route's text, names each event and the
/// schema of its data; in 3.2 its `itemSchema` is an event of `E`.
fn streamAnswer(comptime reg: *const schema.Registry, comptime E: type, comptime text: ?[]const u8, comptime version: DocumentOptions.Version, comptime from: []const u8) Answer {
    const media = "text/event-stream";
    switch (version) {
        .@"3.1" => return .{
            .status = 200,
            .description = if (text) |given| given ++ " " ++ eventsText(reg, E) else eventsText(reg, E),
            .media = media,
            .shape = json.object(&.{string("type", "string")}),
            .from = from,
        },
        .@"3.2" => return .{ .status = 200, .description = text, .media = media, .shape = itemSchema(reg, E), .items = true, .from = from },
    }
}

/// "The events of the stream, each with the schema of its data:
/// todo.created (TodoResponse), todo.deleted (an empty object)."
fn eventsText(comptime reg: *const schema.Registry, comptime E: type) []const u8 {
    const u = @typeInfo(E).@"union";
    var out: []const u8 = "The events of the stream, each with the schema of its data: ";
    for (u.field_names, u.field_types, 0..) |name, P, i| out = out ++ (if (i == 0) "" else ", ") ++ name ++ " (" ++ dataName(reg, P) ++ ")";
    return out ++ ".";
}

/// The schema of the data of an event, in words: the name of its schema,
/// or the kind of its JSON.
fn dataName(comptime reg: *const schema.Registry, comptime P: type) []const u8 {
    if (P == void) return "an empty object";
    if (P == std.json.Value) return "any JSON";
    if (@typeInfo(P) == .optional) return dataName(reg, @typeInfo(P).optional.child) ++ " or null";
    const node = reg.schema(.{ .T = P, .direction = .output });
    if (json.get(node.object, "$ref")) |ref| return ref.string["#/components/schemas/".len..];
    const kind = (json.get(node.object, "type") orelse return "an object").string;
    if (std.mem.eql(u8, kind, "integer")) return "an integer";
    if (std.mem.eql(u8, kind, "array")) return "an array";
    if (std.mem.eql(u8, kind, "object")) return "an object";
    return "a " ++ kind;
}

/// The schema of an event of the stream of `E` in 3.2: one of its
/// variants, each an `event` of its name and a `data` of the JSON of its
/// payload, with the optional `id` and `retry`.
fn itemSchema(comptime reg: *const schema.Registry, comptime E: type) Node {
    const u = @typeInfo(E).@"union";
    var events: [u.field_names.len]Node = undefined;
    for (u.field_names, u.field_types, &events) |name, P, *event| {
        const data = if (P == void)
            json.object(&.{ string("type", "object"), .{ .key = "maxProperties", .value = .{ .raw = "0" } } })
        else
            reg.schema(.{ .T = P, .direction = .output });
        event.* = json.object(&.{
            string("type", "object"),
            .{ .key = "required", .value = .{ .array = &.{ .{ .string = "event" }, .{ .string = "data" } } } },
            .{ .key = "properties", .value = json.object(&.{
                .{ .key = "event", .value = json.object(&.{ string("type", "string"), .{ .key = "const", .value = .{ .string = name } } }) },
                .{ .key = "data", .value = json.object(&.{
                    string("type", "string"),
                    string("contentMediaType", "application/json"),
                    .{ .key = "contentSchema", .value = data },
                }) },
                .{ .key = "id", .value = json.object(&.{string("type", "string")}) },
                .{ .key = "retry", .value = json.object(&.{
                    string("type", "integer"),
                    string("format", "uint64"),
                    .{ .key = "minimum", .value = .{ .raw = "0" } },
                }) },
            }) },
        });
    }
    const final = events;
    return json.object(&.{.{ .key = "oneOf", .value = .{ .array = &final } }});
}

/// A response that a middleware writes itself.
const MiddlewareResponse = struct { status: u16, description: ?[]const u8, content_type: ?[]const u8, json: type };

/// The `.responses` of a `MiddlewareDoc`, by status.
fn middlewareResponses(comptime doc: MiddlewareDoc) []const MiddlewareResponse {
    var out: []const MiddlewareResponse = &.{};
    for (@typeInfo(MiddlewareDoc.Responses).@"struct".field_names) |name| {
        const r = @field(doc.responses, name) orelse continue;
        out = out ++ [_]MiddlewareResponse{.{
            .status = @backingInt(@field(std.http.Status, name)),
            .description = r.description,
            .content_type = r.content_type,
            .json = r.json,
        }};
    }
    return out;
}

/// The responses of an operation, by status: the description of the
/// first answer that has one, else the phrase of the status, and the
/// bodies of all, each under its media type, with the examples of all the
/// answers of that media type. Two bodies of one media type on one status
/// must have the same schema, or the build stops.
fn responsesNode(comptime answers: []const Answer, comptime at: []const u8) Node {
    var statuses: []const u16 = &.{};
    for (answers) |a| statuses = insertStatus(statuses, a.status);
    var out: [statuses.len]Member = undefined;
    for (statuses, &out) |status, *member| {
        var description: ?[]const u8 = null;
        var bodies: []const Answer = &.{};
        for (answers) |a| {
            if (a.status != status) continue;
            if (description == null) description = a.description;
            const media = a.media orelse continue;
            for (bodies, 0..) |b, i| {
                if (!std.mem.eql(u8, b.media.?, media)) continue;
                if (b.items != a.items or !json.eql(b.shape, a.shape))
                    fail(at ++ ": the response " ++ std.fmt.comptimePrint("{d}", .{status}) ++ " has two schemas of " ++ media ++ ", of " ++ b.from ++ " and of " ++ a.from ++
                        "; one media type of a status has one schema");
                var next = bodies[0..bodies.len].*;
                next[i].examples = withExamples(b.examples, a.examples);
                const final = next;
                bodies = &final;
                break;
            } else bodies = bodies ++ [_]Answer{a};
        }
        var content: [bodies.len]Member = undefined;
        for (bodies, &content) |b, *c| {
            var m: []const Member = &.{.{ .key = if (b.items) "itemSchema" else "schema", .value = b.shape }};
            if (b.examples.len > 0) m = m ++ [_]Member{.{ .key = "examples", .value = .{ .object = b.examples } }};
            c.* = .{ .key = b.media.?, .value = .{ .object = m } };
        }
        const final_content = content;
        var m: []const Member = &.{string("description", description orelse phrase(status))};
        if (bodies.len > 0) m = m ++ [_]Member{.{ .key = "content", .value = .{ .object = &final_content } }};
        member.* = .{ .key = std.fmt.comptimePrint("{d}", .{status}), .value = .{ .object = m } };
    }
    const final = out;
    return .{ .object = &final };
}

/// The examples `known`, and those of `more` under names they do not
/// have.
fn withExamples(comptime known: []const Member, comptime more: []const Member) []const Member {
    var out = known;
    for (more) |m| {
        for (known) |k| {
            if (std.mem.eql(u8, k.key, m.key)) break;
        } else out = out ++ [_]Member{m};
    }
    return out;
}

/// `statuses`, sorted, with `status` in its place.
fn insertStatus(comptime statuses: []const u16, comptime status: u16) []const u16 {
    var at: usize = 0;
    while (at < statuses.len and statuses[at] < status) at += 1;
    if (at < statuses.len and statuses[at] == status) return statuses;
    return statuses[0..at] ++ [_]u16{status} ++ statuses[at..];
}

/// The reason phrase of `status` by the names of RFC 9110, as the server
/// writes it in a status line.
fn phrase(comptime status: u16) []const u8 {
    return switch (status) {
        // std names these two as RFC 7231 and RFC 4918 did.
        413 => "Content Too Large",
        422 => "Unprocessable Content",
        else => blk: {
            if (status <= std.math.maxInt(u10)) {
                const known: std.http.Status = @fromBackingInt(@as(u10, @intCast(status)));
                if (known.phrase()) |text| break :blk text;
            }
            break :blk std.fmt.comptimePrint("Status {d}", .{status});
        },
    };
}

fn success(comptime status: u16) bool {
    return status >= 200 and status <= 299;
}

/// A status that goes without content, whatever is written: 204, 205 and
/// 304, as zefir-http sends them.
fn bodiless(comptime status: u16) bool {
    return status == 204 or status == 205 or status == 304;
}

// ------------------------------------------------------------------ the answers to errors

/// The answers of the error handler to the errors of a route at one
/// status: an example of each body, by the name of its error.
const ErrorStatus = struct { status: u16, examples: []const Member };

/// What the error handler `H` answers to each error of `E`, the errors of
/// the route `at`, by status. `mapError` gives each error its status and
/// its body. One example per body, under the name of its error, the first
/// by name of those with that body; at 500, only the errors `mapError`
/// names, and one example `internal` for those its fallback gives 500. An
/// error that ends a request without a response, `Canceled`, has none. A
/// status that is not a final one, 200 to 599, stops the build: the server
/// answers 500 instead.
/// The order is the statuses' and the names', not the error set's: the
/// compiler orders an error set by the errors it met first anywhere in
/// the program.
fn errorStatuses(comptime H: type, comptime E: type, comptime at: []const u8) []const ErrorStatus {
    const names = @typeInfo(E).error_set.error_names orelse
        fail(at ++ " returns anyerror; the document needs the errors it can return: give it an error set");
    const Body = @typeInfo(@TypeOf(H.mapError)).@"fn".return_type.?.Body;
    const problem = Body == http.Problem;
    // A body that writes itself has its JSON only at run time: no examples.
    const shown = !declarations.writesItself(Body);
    const Item = struct { status: u16, name: []const u8, body: Node };
    var items: []const Item = &.{};
    var internal: ?Node = null;
    for (sortedNames(names)) |name| {
        if (std.mem.eql(u8, name, "Canceled") or std.mem.eql(u8, name, "Cancelled")) continue;
        const res = H.mapError(@field(anyerror, name));
        if (res.status < 200 or res.status > 599)
            fail(schema.typeName(H) ++ ".mapError(error." ++ name ++ ") gives the status " ++ std.fmt.comptimePrint("{d}", .{res.status}) ++
                ", which is not a final status of HTTP; give it one of 200 to 599");
        const body: Node = if (shown) example.value(Body, res.body, if (problem) .problem else .output, schema.typeName(H) ++ ".mapError(error." ++ name ++ ")") else .null;
        if (res.status == 500 and res.from_fallback) {
            if (internal == null) internal = body;
            continue;
        }
        items = items ++ [_]Item{.{ .status = res.status, .name = name, .body = body }};
    }
    if (internal) |body| items = items ++ [_]Item{.{ .status = 500, .name = "internal", .body = body }};
    var statuses: []const u16 = &.{};
    for (items) |item| statuses = insertStatus(statuses, item.status);
    var out: [statuses.len]ErrorStatus = undefined;
    for (statuses, &out) |status, *slot| {
        var group: []const Item = &.{};
        for (items) |item| {
            if (item.status == status) group = group ++ [_]Item{item};
        }
        group = sorted(Item, group, struct {
            fn less(a: Item, b: Item) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.less);
        var examples: []const Member = &.{};
        var bodies: []const Node = &.{};
        next: for (if (shown) group else &.{}) |item| {
            for (bodies) |known| {
                if (json.eql(known, item.body)) continue :next;
            }
            examples = examples ++ [_]Member{.{ .key = item.name, .value = json.object(&.{.{ .key = "value", .value = item.body }}) }};
            bodies = bodies ++ [_]Node{item.body};
        }
        slot.* = .{ .status = status, .examples = examples };
    }
    const final = out;
    return &final;
}

/// The names of an error set, sorted.
fn sortedNames(comptime names: anytype) []const []const u8 {
    var list: [names.len][]const u8 = undefined;
    for (names, &list) |name, *item| item.* = name;
    return sorted([]const u8, &list, struct {
        fn less(a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

// ------------------------------------------------------------------ security

/// What a route requires: one of `schemes`, each with `roles`.
const Requirement = struct { schemes: []const []const u8, roles: []const []const u8 };

/// The `security` of `r`, from the middleware of its chain, left to right:
/// the schemes they declare, the `.security` that requires them, the
/// `.roles` they add. Null for a route without `.security` in its chain,
/// which is public.
fn securityNode(comptime r: http.RouteDescription) ?Node {
    const req = requirementOf(r) orelse return null;
    var roles: [req.roles.len]Node = undefined;
    for (req.roles, &roles) |role, *item| item.* = .{ .string = role };
    const final_roles = roles;
    var out: [req.schemes.len]Node = undefined;
    for (req.schemes, &out) |name, *item| item.* = json.object(&.{.{ .key = name, .value = .{ .array = &final_roles } }});
    const final = out;
    return .{ .array = &final };
}

fn requirementOf(comptime r: http.RouteDescription) ?Requirement {
    var declared: []const []const u8 = &.{};
    var required: ?[]const []const u8 = null;
    var roles: []const []const u8 = &.{};
    for (r.chain) |e| {
        const doc = middlewareDoc(e) orelse continue;
        for (doc.security_schemes) |s| {
            if (!contains(declared, s.name)) declared = declared ++ [_][]const u8{s.name};
        }
        if (doc.security) |security| switch (security) {
            .any => {
                if (declared.len == 0)
                    fail(where(r) ++ ": " ++ e.name ++ " requires any scheme declared before it, but no middleware before it declares one; " ++
                        "declare them in the .security_schemes of a middleware before it");
                required = declared;
            },
            .schemes => |names| {
                for (names) |name| {
                    if (!contains(declared, name)) fail(where(r) ++ ": " ++ e.name ++ " requires the scheme " ++ name ++ ", which no middleware before it declares");
                }
                required = names;
            },
        };
        if (doc.roles.len > 0) {
            if (required == null)
                fail(where(r) ++ ": " ++ e.name ++ " adds the roles " ++ joinedWith(doc.roles, ", ") ++ ", but no middleware before it requires a scheme; " ++
                    "put one with .security, such as .security = .any, before it");
            for (doc.roles) |role| {
                if (!contains(roles, role)) roles = roles ++ [_][]const u8{role};
            }
        }
    }
    return .{ .schemes = required orelse return null, .roles = roles };
}

/// The `securitySchemes` of the middleware of the routes, by name; null
/// for none. One name with two different schemes stops the build.
fn securitySchemesNode(comptime routes: []const http.RouteDescription) ?Node {
    const Found = struct { name: []const u8, node: Node, by: []const u8 };
    var found: []const Found = &.{};
    var seen: []const type = &.{};
    for (routes) |r| {
        for (r.chain) |e| {
            if (containsType(seen, e.Impl)) continue;
            seen = seen ++ [_]type{e.Impl};
            const doc = middlewareDoc(e) orelse continue;
            next: for (doc.security_schemes) |s| {
                const node = schemeNode(s, e.name);
                for (found) |f| {
                    if (!std.mem.eql(u8, f.name, s.name)) continue;
                    if (!json.eql(f.node, node))
                        fail("two security schemes named " ++ s.name ++ ", of " ++ f.by ++ " and of " ++ e.name ++ ", are not the same; give one of them another name");
                    continue :next;
                }
                found = found ++ [_]Found{.{ .name = s.name, .node = node, .by = e.name }};
            }
        }
    }
    if (found.len == 0) return null;
    const by_name = sorted(Found, found, struct {
        fn less(a: Found, b: Found) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    var out: [by_name.len]Member = undefined;
    for (by_name, &out) |f, *m| m.* = .{ .key = f.name, .value = f.node };
    const final = out;
    return .{ .object = &final };
}

/// A security scheme, as the middleware `by` declares it.
fn schemeNode(comptime s: MiddlewareDoc.SecurityScheme, comptime by: []const u8) Node {
    if (!isComponentName(s.name))
        fail("the security scheme \"" ++ s.name ++ "\" of " ++ by ++ " is not a name of the document: 1 or more of A-Z, a-z, 0-9, '.', '-' and '_'");
    const kind = switch (s.kind) {
        .http => "http",
        .api_key => "apiKey",
        .oauth2 => "oauth2",
        .open_id_connect => "openIdConnect",
        .mutual_tls => "mutualTLS",
    };
    var m: []const Member = &.{string("type", kind)};
    if (s.description) |text| m = m ++ [_]Member{string("description", text)};
    switch (s.kind) {
        .http => |h| {
            m = m ++ [_]Member{string("scheme", h.scheme)};
            if (h.bearer_format) |text| m = m ++ [_]Member{string("bearerFormat", text)};
        },
        .api_key => |k| m = m ++ [_]Member{ string("name", k.param), string("in", @tagName(k.in)) },
        .oauth2 => |o| {
            var flows: []const Member = &.{};
            const all = [_]struct { []const u8, ?MiddlewareDoc.Flow, bool, bool }{
                .{ "implicit", o.flows.implicit, true, false },
                .{ "password", o.flows.password, false, true },
                .{ "clientCredentials", o.flows.client_credentials, false, true },
                .{ "authorizationCode", o.flows.authorization_code, true, true },
            };
            for (all) |f| {
                const flow = f[1] orelse continue;
                flows = flows ++ [_]Member{.{ .key = f[0], .value = flowNode(flow, f[2], f[3], s.name ++ "." ++ f[0]) }};
            }
            m = m ++ [_]Member{.{ .key = "flows", .value = .{ .object = flows } }};
        },
        .open_id_connect => |o| m = m ++ [_]Member{string("openIdConnectUrl", o.url)},
        .mutual_tls => {},
    }
    return .{ .object = m };
}

/// An OAuth2 flow, which needs its `authorizationUrl`, its `tokenUrl`, or
/// both.
fn flowNode(comptime flow: MiddlewareDoc.Flow, comptime authorization: bool, comptime token: bool, comptime name: []const u8) Node {
    var m: []const Member = &.{};
    if (authorization) m = m ++ [_]Member{string("authorizationUrl", flow.authorization_url orelse
        fail("the OAuth2 flow " ++ name ++ " needs its .authorization_url"))};
    if (token) m = m ++ [_]Member{string("tokenUrl", flow.token_url orelse
        fail("the OAuth2 flow " ++ name ++ " needs its .token_url"))};
    if (flow.refresh_url) |url| m = m ++ [_]Member{string("refreshUrl", url)};
    var scopes: [flow.scopes.len]Member = undefined;
    for (flow.scopes, &scopes) |scope, *s| s.* = string(scope.name, scope.description);
    const final = scopes;
    return .{ .object = m ++ [_]Member{.{ .key = "scopes", .value = .{ .object = &final } }} };
}

/// A key of a map of `components`: `^[a-zA-Z0-9.\-_]+$`.
fn isComponentName(comptime name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    }
    return true;
}

// ------------------------------------------------------------------ components

/// The schemas of the named types and the security schemes; null for
/// none.
fn componentsNode(comptime reg: *const schema.Registry, comptime routes: []const http.RouteDescription) ?Node {
    var m: []const Member = &.{};
    const schemas = reg.components();
    if (schemas.object.len > 0) m = m ++ [_]Member{.{ .key = "schemas", .value = schemas }};
    if (securitySchemesNode(routes)) |schemes| m = m ++ [_]Member{.{ .key = "securitySchemes", .value = schemes }};
    if (m.len == 0) return null;
    return .{ .object = m };
}

// ------------------------------------------------------------------ helpers

fn string(comptime key: []const u8, comptime value: []const u8) Member {
    return .{ .key = key, .value = .{ .string = value } };
}

fn joined(comptime sentences: []const []const u8) []const u8 {
    return joinedWith(sentences, " ");
}

fn joinedWith(comptime parts: []const []const u8, comptime separator: []const u8) []const u8 {
    var out: []const u8 = parts[0];
    for (parts[1..]) |p| out = out ++ separator ++ p;
    return out;
}

fn contains(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn containsType(comptime list: []const type, comptime T: type) bool {
    for (list) |item| {
        if (item == T) return true;
    }
    return false;
}

/// `items` sorted by `less`, stable: a merge sort.
fn sorted(comptime Item: type, comptime items: []const Item, comptime less: anytype) []const Item {
    if (items.len <= 1) return items;
    const half = items.len / 2;
    const left = sorted(Item, items[0..half], less);
    const right = sorted(Item, items[half..], less);
    var out: [items.len]Item = undefined;
    var i: usize = 0;
    var j: usize = 0;
    for (&out) |*slot| {
        if (j == right.len or (i < left.len and !less(right[j], left[i]))) {
            slot.* = left[i];
            i += 1;
        } else {
            slot.* = right[j];
            j += 1;
        }
    }
    const final = out;
    return &final;
}

test {
    _ = @import("tests/document_test.zig");
}
