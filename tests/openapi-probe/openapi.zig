//! The probe of design 1.2 of zefir-openapi, section 16: what it costs the
//! compiler to build the OpenAPI document of an application. Not the
//! module: a generator faithful enough to cost what the module would.
//!
//! It walks the type of the options of `http.Server.init` through the
//! public API of zefir-http (the controllers' `http_routes`, the handlers'
//! function types, `@typeInfo`), as the module will through
//! `http.describe`, and builds a model of the document with its checks:
//! paths and their operations, with parameters, request bodies and
//! responses; the error statuses of every route from the error handler's
//! `mapError`, with an example body each; one schema per DTO type, with the
//! keywords of its `field_rules` and `$ref` between types; names sorted,
//! two types of one schema name and two operations of one operationId
//! refused. Then each variant gives the document its own way:
//!
//! - `A`: the JSON at compile time, a constant of the binary. `render`
//!   writes the model twice, first into a counter of its length, then
//!   into an array of that length; each JSON string is escaped by a pure
//!   function, which the compiler memoizes, so once per distinct string;
//! - `B`: the model is data of the binary, and `write` writes the JSON at
//!   run time, with the same writer;
//! - `Naive`: the JSON at compile time, each piece appended with `++`;
//! - `None`: no document, the baseline.
//!
//! The application declares its texts in typed `pub const openapi`, as
//! design 1.2 says. zefir-http does not take `.path`, `.query`, `.body` and
//! `.responses` in a route's options yet, so the probe reads the route's
//! input and the status of its JSON value from its entry in
//! `ControllerDoc`.
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const Error = std.Io.Writer.Error;
/// The elements of an entry of `field_rules` besides the rules, which the
/// validator does not export by name.
const Rename = @typeInfo(@TypeOf(v.rename)).@"fn".return_type.?;
const Transform = @TypeOf(v.trim);
const Kind = @FieldType(v.Rule, "kind");

// ------------------------------------------------------------------ the declarations of the application

/// The texts of a field of a DTO.
pub const FieldDoc = struct {
    description: ?[]const u8 = null,
};

/// `pub const openapi: openapi.Doc(@This()) = .{ ... }` of a DTO: its text
/// and the texts of its fields.
pub fn Doc(comptime T: type) type {
    return struct {
        description: ?[]const u8 = null,
        fields: FieldsDoc(T) = .{},
    };
}

fn FieldsDoc(comptime T: type) type {
    const names = @typeInfo(T).@"struct".field_names;
    const none: FieldDoc = .{};
    return @Struct(.auto, null, names, &@splat(FieldDoc), &@splat(.{ .default_value_ptr = &none }));
}

/// A route of a controller: its texts, and what design 1.2 puts in the
/// route's options, the DTOs of its input and the status of its JSON value.
pub const RouteDoc = struct {
    summary: []const u8,
    description: ?[]const u8 = null,
    path: type = void,
    query: type = void,
    body: type = void,
    status: u16 = 200,
};

/// `pub const openapi: openapi.ControllerDoc(@This()) = .{ ... }` of a
/// controller: its tag, and an entry for every method of `.methods`.
pub fn ControllerDoc(comptime C: type) type {
    return struct {
        tag: []const u8,
        description: ?[]const u8 = null,
        routes: RoutesDoc(C),
    };
}

fn RoutesDoc(comptime C: type) type {
    const names = @typeInfo(@TypeOf(C.http_routes.methods)).@"struct".field_names;
    return @Struct(.auto, null, names, &@splat(RouteDoc), &@splat(.{}));
}

// ------------------------------------------------------------------ the model

/// A JSON value: an example, or a default.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    string: []const u8,
    array: []const Value,
    object: []const Member,
};

pub const Member = struct { name: []const u8, value: Value };

/// A keyword with a number: `minimum`, `maxLength`, ...
pub const Keyword = struct { name: []const u8, value: i64 };

pub const Schema = struct {
    /// "#/components/schemas/Name"; the other fields but `nullable` and
    /// `description` are empty then.
    ref: ?[]const u8 = null,
    json_type: []const u8 = "",
    /// Null is a value too: ["string", "null"], or oneOf with a ref.
    nullable: bool = false,
    format: ?[]const u8 = null,
    description: ?[]const u8 = null,
    numbers: []const Keyword = &.{},
    pattern: ?[]const u8 = null,
    enum_values: []const []const u8 = &.{},
    default: ?Value = null,
    items: ?*const Schema = null,
    object: bool = false,
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    /// `additionalProperties: false`.
    closed: bool = false,
};

pub const Property = struct { name: []const u8, schema: Schema };

pub const Parameter = struct {
    name: []const u8,
    in: []const u8,
    required: bool,
    description: ?[]const u8 = null,
    /// A list in the query: `style: form, explode: true`.
    exploded: bool = false,
    schema: Schema,
};

pub const Example = struct { name: []const u8, value: Value };

pub const Content = struct {
    media_type: []const u8,
    schema: Schema,
    examples: []const Example = &.{},
};

pub const Response = struct {
    status: []const u8,
    description: []const u8,
    content: ?Content = null,
};

pub const Operation = struct {
    method: []const u8,
    operation_id: []const u8,
    tag: []const u8,
    summary: []const u8,
    description: ?[]const u8 = null,
    parameters: []const Parameter = &.{},
    request_body: ?Content = null,
    responses: []const Response,
};

pub const PathItem = struct { path: []const u8, operations: []const Operation };

pub const Tag = struct { name: []const u8, description: ?[]const u8 = null };

pub const NamedSchema = struct { name: []const u8, schema: Schema };

pub const Document = struct {
    title: []const u8,
    version: []const u8,
    /// The server's prefix, when the options know it at compile time.
    server: ?[]const u8 = null,
    tags: []const Tag,
    paths: []const PathItem,
    schemas: []const NamedSchema,
};

// ------------------------------------------------------------------ the variants

/// No document: the baseline.
pub const None = struct {
    pub const Result = void;

    pub fn document(comptime O: type) void {
        _ = O;
    }
};

/// The JSON of the document, built at compile time by pure functions that
/// return the text of each object and array (`documentText`).
pub const A = struct {
    pub const Result = []const u8;

    pub fn document(comptime O: type) []const u8 {
        return comptime renderTree(O);
    }
};

/// The JSON of the document, built at compile time through the writer of
/// B: its length counted first, then one array of that length filled.
pub const AFill = struct {
    pub const Result = []const u8;

    pub fn document(comptime O: type) []const u8 {
        return comptime render(O);
    }
};

/// The first pass of `AFill` alone, for a diagnosis: no document.
pub const ACount = struct {
    pub const Result = []const u8;

    pub fn document(comptime O: type) []const u8 {
        return comptime countOnly(O);
    }
};

/// The model, built at compile time; `write` gives the JSON at run time.
pub const B = struct {
    pub const Result = *const Document;

    pub fn document(comptime O: type) *const Document {
        return comptime model(O);
    }
};

/// The JSON at compile time, each piece appended with `++`.
pub const Naive = struct {
    pub const Result = []const u8;

    pub fn document(comptime O: type) []const u8 {
        return comptime renderNaive(O);
    }
};

/// The JSON of `doc` into `w`: variant B, at run time.
pub fn write(w: *std.Io.Writer, doc: *const Document) Error!void {
    var stream: Stream = .{ .w = w };
    return writeDocument(&stream, doc);
}

/// The eval branch quota: a base, and a share for every route. Building
/// the model and writing it at compile time run in one evaluation, so
/// `render` sets the sum.
const model_quota = .{ .base = 1_000_000, .per_route = 200_000 };
const render_quota = .{ .base = 1_000_000, .per_route = 400_000 };

/// A root module that declares `pub const openapi_quota: u32` sets the
/// quota itself: `measure.sh --quota` so searches for the smallest that
/// builds (see `TransformErrorOf`).
fn quotaOf(comptime routes: usize, comptime base: u64, comptime per_route: u64) u32 {
    const root = @import("root");
    if (@hasDecl(root, "openapi_quota")) return root.openapi_quota;
    return @intCast(@min(std.math.maxInt(u32), base + per_route * routes));
}

/// The document as JSON, at compile time: its length first, then one array
/// of that length, filled once.
fn render(comptime O: type) []const u8 {
    comptime {
        const routes = routesIn(O);
        @setEvalBranchQuota(quotaOf(routes, model_quota.base + render_quota.base, model_quota.per_route + render_quota.per_route));
        const doc = model(O);
        var counter: Counter = .{};
        writeDocument(&counter, doc) catch unreachable;
        var buf: [counter.len]u8 = undefined;
        var filler: Filler = .{ .buf = &buf };
        writeDocument(&filler, doc) catch unreachable;
        const final = buf;
        return &final;
    }
}

/// The length of the document, at compile time, and nothing else.
fn countOnly(comptime O: type) []const u8 {
    comptime {
        const routes = routesIn(O);
        @setEvalBranchQuota(quotaOf(routes, model_quota.base + render_quota.base, model_quota.per_route + render_quota.per_route));
        const doc = model(O);
        var counter: Counter = .{};
        writeDocument(&counter, doc) catch unreachable;
        if (counter.len == 0) unreachable;
        return "";
    }
}

/// The document as JSON, at compile time, by the pure functions of
/// `documentText`.
fn renderTree(comptime O: type) []const u8 {
    comptime {
        const routes = routesIn(O);
        @setEvalBranchQuota(quotaOf(routes, model_quota.base + render_quota.base, model_quota.per_route + render_quota.per_route));
        return documentText(model(O).*);
    }
}

/// The document as JSON, at compile time, by `++`.
fn renderNaive(comptime O: type) []const u8 {
    comptime {
        const routes = routesIn(O);
        @setEvalBranchQuota(quotaOf(routes, model_quota.base + render_quota.base, model_quota.per_route + render_quota.per_route));
        const doc = model(O);
        var appender: Appender = .{};
        writeDocument(&appender, doc) catch unreachable;
        return appender.text;
    }
}

// ------------------------------------------------------------------ the walk

const Dir = enum { input, output };

/// A route, with the path its operation goes under.
const Located = struct { path: []const u8, operation: Operation };

/// The model of the document of a server built from options of type `O`.
pub fn model(comptime O: type) *const Document {
    comptime {
        @setEvalBranchQuota(quotaOf(routesIn(O), model_quota.base, model_quota.per_route));
        const H = errorHandlerOf(O);
        const ErrorBody = @typeInfo(@TypeOf(H.mapError)).@"fn".return_type.?.Body;
        const controllers = controllersOf(O);

        // The struct types the document describes, and the directions they
        // go in: a type sent both ways gets a schema for each.
        var seen: []const Occurrence = occurrencesOf(ErrorBody, .output);
        for (controllers) |C| {
            const docs = controllerDoc(C);
            for (methodNames(C)) |name| {
                const route: RouteDoc = @field(docs.routes, name);
                if (route.body != void) seen = seen ++ occurrencesOf(route.body, .input);
                const Answer = answerOf(C, name);
                if (Answer != void) seen = seen ++ occurrencesOf(Answer, .output);
            }
        }
        const uses = usesOf(seen);

        const error_media = if (ErrorBody == http.Problem) "application/problem+json" else "application/json";
        const error_schema = typeSchema(ErrorBody, &.{}, .output, uses);
        const Global = if (@hasField(O, "middleware")) chainErrors(@FieldType(O, "middleware"), void) else error{};

        var tags: []const Tag = &.{};
        var located: []const Located = &.{};
        for (controllers) |C| {
            const docs = controllerDoc(C);
            tags = tags ++ [_]Tag{.{ .name = docs.tag, .description = docs.description }};
            const R = C.http_routes;
            const ControllerErrors = chainErrors(@TypeOf(R.middleware), C);
            for (methodNames(C)) |name| {
                const Route = @field(R.methods, name);
                const route: RouteDoc = @field(docs.routes, name);
                const Answer = answerOf(C, name);
                // The errors the strict error check reads for the route:
                // its chain, its handler, the transforms of its value.
                const Errors = Global || ControllerErrors || chainErrors(@TypeOf(Route.middleware), C) ||
                    handlerErrors(C, name) || (if (Answer == void) error{} else TransformErrorOf(Answer));
                var parameters: []const Parameter = &.{};
                if (route.path != void) parameters = parameters ++ parametersOf(route.path, "path");
                if (route.query != void) parameters = parameters ++ parametersOf(route.query, "query");
                const success: Response = if (Answer == void) .{
                    .status = "204",
                    .description = "No Content",
                } else .{
                    .status = statusText(route.status),
                    .description = reason(route.status),
                    .content = .{ .media_type = "application/json", .schema = typeSchema(Answer, &.{}, .output, uses) },
                };
                const request_body: ?Content = if (route.body == void) null else .{
                    .media_type = "application/json",
                    .schema = typeSchema(route.body, &.{}, .input, uses),
                };
                const responses: []const Response = &[_]Response{success} ++ errorResponses(H, Errors, error_media, error_schema);
                located = located ++ [_]Located{.{ .path = R.prefix ++ Route.route_path, .operation = .{
                    .method = methodName(Route.http_method),
                    .operation_id = docs.tag ++ "." ++ name,
                    .tag = docs.tag,
                    .summary = route.summary,
                    .description = route.description,
                    .parameters = parameters,
                    .request_body = request_body,
                    .responses = responses,
                } }};
            }
        }
        checkOperationIds(located);

        const final: Document = .{
            .title = "Probe API",
            .version = "1.0.0",
            .server = serverOf(O),
            .tags = tags,
            .paths = pathsOf(located),
            .schemas = schemasOf(uses),
        };
        return &final;
    }
}

fn routesIn(comptime O: type) usize {
    comptime {
        var count: usize = 0;
        for (controllersOf(O)) |C| count += methodNames(C).len;
        return count;
    }
}

fn controllersOf(comptime O: type) []const type {
    comptime {
        const info = @typeInfo(@FieldType(O, "controllers")).@"struct";
        var out: [info.field_types.len]type = undefined;
        for (info.field_types, &out) |P, *C| C.* = @typeInfo(P).pointer.child;
        const final = out;
        return &final;
    }
}

fn methodNames(comptime C: type) []const [:0]const u8 {
    return @typeInfo(@TypeOf(C.http_routes.methods)).@"struct".field_names;
}

fn controllerDoc(comptime C: type) ControllerDoc(C) {
    const name = @typeName(C);
    if (!@hasDecl(C, "openapi"))
        @compileError("zefir.openapi: " ++ name ++ " has no pub const openapi: zefir.openapi.ControllerDoc(" ++ name ++ ")");
    if (@TypeOf(C.openapi) != ControllerDoc(C))
        @compileError("zefir.openapi: " ++ name ++ ".openapi must be zefir.openapi.ControllerDoc(" ++ name ++ ")");
    return C.openapi;
}

fn errorHandlerOf(comptime O: type) type {
    if (!@hasField(O, "error_handler")) @compileError("zefir.openapi probe: the options need .error_handler");
    return @typeInfo(@FieldType(O, "error_handler")).pointer.child;
}

/// The type of the JSON value the handler `name` of `C` answers with, or
/// void.
fn answerOf(comptime C: type, comptime name: []const u8) type {
    const R = @typeInfo(@TypeOf(@field(C, name))).@"fn".return_type.?;
    const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
    return if (Payload == void) void else Payload.Value;
}

/// `v.TransformError(T)`, evaluated in a declaration of its own: the
/// validator raises the eval branch quota of the evaluation that calls it
/// to 10 million, which would hide the quota the document needs.
fn TransformErrorOf(comptime T: type) type {
    return struct {
        const Set = v.TransformError(T);
    }.Set;
}

fn handlerErrors(comptime C: type, comptime name: []const u8) type {
    return fnErrors(@TypeOf(@field(C, name)));
}

fn fnErrors(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.error_set else error{};
}

fn runErrors(comptime T: type) type {
    return if (@hasDecl(T, "run")) fnErrors(@TypeOf(T.run)) else error{};
}

/// The errors of the `run` phases of a `.middleware` list: functions,
/// types, pointers to objects, fields of the controller `C`, and sets.
fn chainErrors(comptime List: type, comptime C: type) type {
    comptime {
        const info = @typeInfo(List).@"struct";
        var E: type = error{};
        for (info.field_types, info.field_attrs) |F, attrs| E = E || elementErrors(F, attrs, C);
        return E;
    }
}

fn elementErrors(comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime C: type) type {
    switch (@typeInfo(F)) {
        .@"fn" => return fnErrors(F),
        .pointer => |p| return runErrors(p.child),
        .@"struct" => |s| if (s.is_tuple) return chainErrors(F, C),
        else => {},
    }
    if (F == type) return runErrors(attrs.defaultValue(type).?);
    if (F == @EnumLiteral()) {
        const field = @tagName(attrs.defaultValue(@EnumLiteral()).?);
        return runErrors(@typeInfo(@FieldType(C, field)).pointer.child);
    }
    @compileError("zefir.openapi probe: no middleware element of type " ++ @typeName(F));
}

/// The errors the server answers itself, which no route documents (design
/// 1.2, section 8), and those that end a request without a response.
fn answeredByServer(comptime err: anyerror) bool {
    return switch (err) {
        error.RouteNotFound,
        error.MethodNotAllowed,
        error.Overloaded,
        error.ConcurrencyUnavailable,
        error.RequestTimeout,
        error.DeadlineExceeded,
        error.Canceled,
        error.Cancelled,
        => true,
        else => false,
    };
}

/// An error of a route, as `mapError` answers it.
const Mapped = struct {
    status: u16,
    name: []const u8,
    /// Given 500 by the fallback branch: these share the example `internal`.
    internal: bool,
    value: Value,
};

fn lessMapped(a: Mapped, b: Mapped) bool {
    if (a.status != b.status) return a.status < b.status;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// A response for every status of the errors `E`, by status, with an
/// example for every distinct body, named by the first error that gives it.
fn errorResponses(comptime H: type, comptime E: type, comptime media: []const u8, comptime schema: Schema) []const Response {
    comptime {
        const names = @typeInfo(E).error_set.error_names orelse
            @compileError("zefir.openapi: a route returns anyerror; give it an error set");
        var mapped: []const Mapped = &.{};
        for (names) |name| {
            const err = @field(anyerror, name);
            if (answeredByServer(err)) continue;
            const res = H.mapError(err);
            mapped = mapped ++ [_]Mapped{.{
                .status = res.status,
                .name = name,
                .internal = res.from_fallback and res.status == 500,
                .value = valueOf(res.body),
            }};
        }
        const order = sorted(Mapped, mapped, lessMapped);
        var out: []const Response = &.{};
        var at: usize = 0;
        while (at < order.len) {
            const status = order[at].status;
            var examples: []const Example = &.{};
            var internal = false;
            while (at < order.len and order[at].status == status) : (at += 1) {
                const m = order[at];
                if (m.internal) {
                    if (!internal) examples = examples ++ [_]Example{.{ .name = "internal", .value = m.value }};
                    internal = true;
                } else if (!hasValue(examples, m.value)) {
                    examples = examples ++ [_]Example{.{ .name = m.name, .value = m.value }};
                }
            }
            out = out ++ [_]Response{.{
                .status = statusText(status),
                .description = reason(status),
                .content = .{ .media_type = media, .schema = schema, .examples = examples },
            }};
        }
        return out;
    }
}

fn hasValue(comptime examples: []const Example, comptime value: Value) bool {
    for (examples) |example| {
        if (valueEql(example.value, value)) return true;
    }
    return false;
}

fn valueEql(comptime a: Value, comptime b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .null => return true,
        .bool => |x| return x == b.bool,
        .int => |x| return x == b.int,
        .string => |x| return std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (x.len != b.array.len) return false;
            for (x, b.array) |p, q| {
                if (!valueEql(p, q)) return false;
            }
            return true;
        },
        .object => |x| {
            if (x.len != b.object.len) return false;
            for (x, b.object) |p, q| {
                if (!std.mem.eql(u8, p.name, q.name) or !valueEql(p.value, q.value)) return false;
            }
            return true;
        },
    }
}

/// `x` as JSON, as the codec writes it: fields by their outside names.
fn valueOf(comptime x: anytype) Value {
    comptime {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .bool => return .{ .bool = x },
            .int, .comptime_int => return .{ .int = x },
            .@"enum" => return .{ .string = @tagName(x) },
            .optional => return if (x) |inner| valueOf(inner) else .null,
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return .{ .string = x };
                if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return .{ .string = x };
                if (p.size == .slice) {
                    var items: [x.len]Value = undefined;
                    for (x, &items) |item, *slot| slot.* = valueOf(item);
                    const final = items;
                    return .{ .array = &final };
                }
            },
            .@"struct" => |s| {
                var members: []const Member = &.{};
                for (s.field_names, s.field_attrs) |name, attrs| {
                    if (attrs.@"comptime") continue;
                    members = members ++ [_]Member{.{ .name = entryOf(T, name).name orelse name, .value = valueOf(@field(x, name)) }};
                }
                return .{ .object = members };
            },
            else => {},
        }
        @compileError("zefir.openapi: no JSON value of " ++ @typeName(T));
    }
}

// ------------------------------------------------------------------ parameters and schemas

/// The fields of the DTO `T` as parameters `in` the path or the query.
fn parametersOf(comptime T: type, comptime in: []const u8) []const Parameter {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: []const Parameter = &.{};
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            if (attrs.@"comptime") continue;
            const entry = entryOf(T, name);
            const optional = @typeInfo(F) == .optional;
            const Plain = if (optional) @typeInfo(F).optional.child else F;
            var schema = typeSchema(Plain, entry.rules, .input, &.{});
            if (attrs.defaultValue(F)) |default| {
                const value = valueOf(default);
                if (value != .null) schema.default = value;
            }
            out = out ++ [_]Parameter{.{
                .name = entry.name orelse name,
                .in = in,
                .required = std.mem.eql(u8, in, "path") or (!optional and attrs.default_value_ptr == null),
                .description = fieldDescription(T, name),
                .exploded = Plain != []const u8 and @typeInfo(Plain) == .pointer,
                .schema = schema,
            }};
        }
        return out;
    }
}

/// The schema of a value of type `T` with the rules of its field.
fn typeSchema(comptime T: type, comptime rules: []const v.Rule, comptime dir: Dir, comptime uses: []const Use) Schema {
    comptime {
        switch (@typeInfo(T)) {
            .optional => |o| {
                var s = typeSchema(o.child, rules, dir, uses);
                s.nullable = true;
                return s;
            },
            .bool => return .{ .json_type = "boolean" },
            .int => |i| {
                var limits: Limits = .{};
                if (i.bits <= 32) {
                    limits.minimum = std.math.minInt(T);
                    limits.maximum = std.math.maxInt(T);
                } else if (i.signedness == .unsigned) {
                    limits.minimum = 0;
                }
                applyBounds(&limits, rules);
                return .{ .json_type = "integer", .format = intFormat(i.signedness == .signed, i.bits), .numbers = keywords(limits) };
            },
            .float => |f| {
                var limits: Limits = .{};
                applyBounds(&limits, rules);
                return .{ .json_type = "number", .format = if (f.bits == 32) "float" else "double", .numbers = keywords(limits) };
            },
            .@"enum" => |e| return .{ .json_type = "string", .enum_values = plainNames(e.field_names) },
            .pointer => |p| {
                if (T == []const u8) return stringSchema(rules);
                if (p.size == .slice) {
                    const item = typeSchema(p.child, eachRules(rules), dir, uses);
                    var limits: Limits = .{};
                    applyBounds(&limits, rules);
                    return .{ .json_type = "array", .items = &item, .numbers = keywords(limits) };
                }
            },
            .@"struct" => return .{ .ref = "#/components/schemas/" ++ componentName(T, dir, uses) },
            else => {},
        }
        @compileError("zefir.openapi: " ++ @typeName(T) ++ " has no JSON Schema");
    }
}

fn stringSchema(comptime rules: []const v.Rule) Schema {
    comptime {
        var limits: Limits = .{};
        applyBounds(&limits, rules);
        var s: Schema = .{ .json_type = "string", .numbers = keywords(limits) };
        for (rules) |rule| {
            if (formatOf(rule.kind)) |format| s.format = format;
            switch (rule.kind) {
                .not_blank => s.pattern = "[^\\t\\n\\r ]",
                .one_of => s.enum_values = listedStrings(rule.params[0].value),
                else => {},
            }
        }
        return s;
    }
}

fn formatOf(comptime kind: Kind) ?[]const u8 {
    return switch (kind) {
        .email => "email",
        .http_url => "uri",
        .uuid => "uuid",
        .date => "date",
        .rfc3339 => "date-time",
        .ipv4 => "ipv4",
        .ipv6 => "ipv6",
        .fqdn => "hostname",
        else => null,
    };
}

fn listedStrings(comptime value: anytype) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (value.list) |item| switch (item) {
            .string => |text| out = out ++ [_][]const u8{text},
            .tag => |text| out = out ++ [_][]const u8{text},
            else => {},
        };
        return out;
    }
}

fn eachRules(comptime rules: []const v.Rule) []const v.Rule {
    comptime {
        for (rules) |rule| {
            if (rule.kind == .each) return rule.inner;
        }
        return &.{};
    }
}

fn intFormat(comptime signed: bool, comptime bits: u16) []const u8 {
    return std.fmt.comptimePrint("{s}int{d}", .{ if (signed) "" else "u", bits });
}

fn plainNames(comptime names: []const [:0]const u8) []const []const u8 {
    comptime {
        var out: [names.len][]const u8 = undefined;
        for (names, &out) |name, *slot| slot.* = name;
        const final = out;
        return &final;
    }
}

/// The numeric keywords of a schema, the tighter of two on one side.
const Limits = struct {
    minimum: ?i64 = null,
    exclusive_minimum: ?i64 = null,
    maximum: ?i64 = null,
    exclusive_maximum: ?i64 = null,
    min_length: ?i64 = null,
    max_length: ?i64 = null,
    min_items: ?i64 = null,
    max_items: ?i64 = null,
};

/// Takes the bounds of `rules` into `limits`: the value of a number, the
/// code points of a string, the items of a list.
fn applyBounds(comptime limits: *Limits, comptime rules: []const v.Rule) void {
    comptime {
        for (rules) |rule| {
            for (rule.bounds) |b| {
                const x: i64 = switch (b.value) {
                    .int => |n| n,
                    else => continue,
                };
                const lower = b.side == .lower;
                switch (b.measure) {
                    .value => if (lower) {
                        if (b.inclusive) raise(&limits.minimum, x) else raise(&limits.exclusive_minimum, x);
                    } else {
                        if (b.inclusive) cut(&limits.maximum, x) else cut(&limits.exclusive_maximum, x);
                    },
                    .code_points => if (lower) raise(&limits.min_length, x) else cut(&limits.max_length, x),
                    .items => if (lower) raise(&limits.min_items, x) else cut(&limits.max_items, x),
                    else => {},
                }
            }
        }
    }
}

fn raise(comptime slot: *?i64, comptime x: i64) void {
    slot.* = if (slot.*) |old| @max(old, x) else x;
}

fn cut(comptime slot: *?i64, comptime x: i64) void {
    slot.* = if (slot.*) |old| @min(old, x) else x;
}

fn keywords(comptime l: Limits) []const Keyword {
    comptime {
        var out: []const Keyword = &.{};
        // An exclusive bound at or past the inclusive one makes it moot.
        if (l.minimum) |x| {
            if (l.exclusive_minimum == null or l.exclusive_minimum.? < x) out = out ++ [_]Keyword{.{ .name = "minimum", .value = x }};
        }
        if (l.exclusive_minimum) |x| {
            if (l.minimum == null or l.minimum.? <= x) out = out ++ [_]Keyword{.{ .name = "exclusiveMinimum", .value = x }};
        }
        if (l.maximum) |x| {
            if (l.exclusive_maximum == null or l.exclusive_maximum.? > x) out = out ++ [_]Keyword{.{ .name = "maximum", .value = x }};
        }
        if (l.exclusive_maximum) |x| {
            if (l.maximum == null or l.maximum.? >= x) out = out ++ [_]Keyword{.{ .name = "exclusiveMaximum", .value = x }};
        }
        if (l.min_length) |x| out = out ++ [_]Keyword{.{ .name = "minLength", .value = x }};
        if (l.max_length) |x| out = out ++ [_]Keyword{.{ .name = "maxLength", .value = x }};
        if (l.min_items) |x| out = out ++ [_]Keyword{.{ .name = "minItems", .value = x }};
        if (l.max_items) |x| out = out ++ [_]Keyword{.{ .name = "maxItems", .value = x }};
        return out;
    }
}

/// The schema of the struct `T` in `dir`: its properties by outside names,
/// what is required, and the keywords of its rules.
fn structSchema(comptime T: type, comptime dir: Dir, comptime uses: []const Use) Schema {
    comptime {
        const info = @typeInfo(T).@"struct";
        var properties: []const Property = &.{};
        var required: []const []const u8 = &.{};
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            if (attrs.@"comptime") continue;
            const entry = entryOf(T, name);
            const outside: []const u8 = entry.name orelse name;
            var s = typeSchema(F, entry.rules, dir, uses);
            s.description = fieldDescription(T, name);
            if (dir == .input) {
                if (attrs.defaultValue(F)) |default| {
                    const value = valueOf(default);
                    if (value != .null) s.default = value;
                }
            }
            properties = properties ++ [_]Property{.{ .name = outside, .schema = s }};
            // Input: what has no default and is not optional. Output: all,
            // since the codec writes every field, null too.
            const needed = switch (dir) {
                .output => true,
                .input => @typeInfo(F) != .optional and attrs.default_value_ptr == null,
            };
            if (needed) required = required ++ [_][]const u8{outside};
        }
        return .{
            .json_type = "object",
            .object = true,
            .description = typeDescription(T),
            .properties = properties,
            .required = required,
            .closed = dir == .input and !ignoresUnknown(T),
        };
    }
}

fn ignoresUnknown(comptime T: type) bool {
    if (!@hasDecl(T, "unknown_fields")) return false;
    return @as(http.UnknownFields, T.unknown_fields) == .ignore;
}

fn docOf(comptime T: type) ?Doc(T) {
    if (!@hasDecl(T, "openapi")) return null;
    if (@TypeOf(T.openapi) != Doc(T))
        @compileError("zefir.openapi: " ++ @typeName(T) ++ ".openapi must be zefir.openapi.Doc(" ++ @typeName(T) ++ ")");
    return T.openapi;
}

fn typeDescription(comptime T: type) ?[]const u8 {
    return if (docOf(T)) |doc| doc.description else null;
}

fn fieldDescription(comptime T: type, comptime name: []const u8) ?[]const u8 {
    return if (docOf(T)) |doc| @field(doc.fields, name).description else null;
}

/// The outside name and the rules of a field, from its entry in
/// `field_rules`; transforms change no keyword here.
const Entry = struct {
    name: ?[]const u8 = null,
    rules: []const v.Rule = &.{},
};

fn entryOf(comptime T: type, comptime field: []const u8) Entry {
    comptime {
        if (!@hasDecl(T, "field_rules")) return .{};
        if (!@hasField(@TypeOf(T.field_rules), field)) return .{};
        const value = @field(T.field_rules, field);
        var entry: Entry = .{};
        const E = @TypeOf(value);
        if (E == Rename or E == Transform or E == v.Rule) {
            addPart(&entry, value);
        } else {
            for (0..value.len) |i| addPart(&entry, value[i]);
        }
        return entry;
    }
}

fn addPart(comptime entry: *Entry, comptime part: anytype) void {
    const P = @TypeOf(part);
    if (P == Rename) entry.name = part.name;
    if (P == v.Rule) entry.rules = entry.rules ++ [_]v.Rule{part};
}

// ------------------------------------------------------------------ component names

/// A struct type met in one direction.
const Occurrence = struct { name: []const u8, T: type, dir: Dir };

/// A struct type of the document, and the directions it goes in.
const Use = struct { name: []const u8, T: type, input: bool = false, output: bool = false };

fn lessOccurrence(comptime a: Occurrence, comptime b: Occurrence) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn occurrencesOf(comptime T: type, comptime dir: Dir) []const Occurrence {
    comptime {
        var out: []const Occurrence = &.{};
        for (structsIn(T)) |S| out = out ++ [_]Occurrence{.{ .name = schemaName(S), .T = S, .dir = dir }};
        return out;
    }
}

/// `T` and the struct types of its fields, at every depth.
fn structsIn(comptime T: type) []const type {
    comptime {
        switch (@typeInfo(T)) {
            .optional => |o| return structsIn(o.child),
            .pointer => |p| return if (T == []const u8) &.{} else structsIn(p.child),
            .@"struct" => |s| {
                var out: []const type = &.{T};
                for (s.field_types, s.field_attrs) |F, attrs| {
                    if (!attrs.@"comptime") out = out ++ structsIn(F);
                }
                return out;
            },
            else => return &.{},
        }
    }
}

/// The uses of every struct type, sorted by name; two types of one name
/// stop the build.
fn usesOf(comptime occurrences: []const Occurrence) []const Use {
    comptime {
        const order = sorted(Occurrence, occurrences, lessOccurrence);
        var out: [order.len]Use = undefined;
        var count: usize = 0;
        for (order) |o| {
            if (count > 0 and std.mem.eql(u8, out[count - 1].name, o.name)) {
                if (out[count - 1].T != o.T) @compileError("zefir.openapi: two types have the schema name " ++ o.name ++ ": " ++
                    @typeName(out[count - 1].T) ++ " and " ++ @typeName(o.T));
            } else {
                out[count] = .{ .name = o.name, .T = o.T };
                count += 1;
            }
            switch (o.dir) {
                .input => out[count - 1].input = true,
                .output => out[count - 1].output = true,
            }
        }
        const final = out[0..count].*;
        return &final;
    }
}

fn findUse(comptime uses: []const Use, comptime name: []const u8) Use {
    comptime {
        var low: usize = 0;
        var high: usize = uses.len;
        while (low < high) {
            const middle = (low + high) / 2;
            switch (std.mem.order(u8, uses[middle].name, name)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return uses[middle],
            }
        }
        @compileError("zefir.openapi probe: internal: no schema " ++ name);
    }
}

/// The name of the component of `T` in `dir`: its schema name, and
/// `-Input` or `-Output` for a type that goes both ways.
fn componentName(comptime T: type, comptime dir: Dir, comptime uses: []const Use) []const u8 {
    comptime {
        const use = findUse(uses, schemaName(T));
        if (!(use.input and use.output)) return use.name;
        return use.name ++ switch (dir) {
            .input => "-Input",
            .output => "-Output",
        };
    }
}

/// The last part of the name of `T`, with the names of its arguments:
/// `app.Page(app.Summary0_0)` is `Page_Summary0_0`.
fn schemaName(comptime T: type) []const u8 {
    comptime {
        const full = @typeName(T);
        var out: []const u8 = "";
        var start: usize = 0;
        for (full, 0..) |c, i| switch (c) {
            '.', ' ' => start = i + 1,
            '(', ',' => {
                out = out ++ full[start..i] ++ "_";
                start = i + 1;
            },
            ')' => {
                out = out ++ full[start..i];
                start = i + 1;
            },
            else => {},
        };
        return out ++ full[start..];
    }
}

/// The components, sorted by name.
fn schemasOf(comptime uses: []const Use) []const NamedSchema {
    comptime {
        var out: []const NamedSchema = &.{};
        for (uses) |use| {
            if (use.input) out = out ++ [_]NamedSchema{.{ .name = componentName(use.T, .input, uses), .schema = structSchema(use.T, .input, uses) }};
            if (use.output) out = out ++ [_]NamedSchema{.{ .name = componentName(use.T, .output, uses), .schema = structSchema(use.T, .output, uses) }};
        }
        return out;
    }
}

// ------------------------------------------------------------------ paths

/// The operations by path, the paths in the order of their first route.
fn pathsOf(comptime located: []const Located) []const PathItem {
    comptime {
        var paths: []const []const u8 = &.{};
        for (located) |l| {
            for (paths) |p| {
                if (std.mem.eql(u8, p, l.path)) break;
            } else paths = paths ++ [_][]const u8{l.path};
        }
        var out: [paths.len]PathItem = undefined;
        for (paths, &out) |p, *item| {
            var operations: []const Operation = &.{};
            for (located) |l| {
                if (std.mem.eql(u8, l.path, p)) operations = operations ++ [_]Operation{l.operation};
            }
            item.* = .{ .path = p, .operations = operations };
        }
        const final = out;
        return &final;
    }
}

fn lessText(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn checkOperationIds(comptime located: []const Located) void {
    comptime {
        var ids: [located.len][]const u8 = undefined;
        for (located, &ids) |l, *id| id.* = l.operation.operation_id;
        const all = ids;
        const order = sorted([]const u8, &all, lessText);
        for (1..order.len) |i| {
            if (std.mem.eql(u8, order[i - 1], order[i])) @compileError("zefir.openapi: two operations have the operationId " ++ order[i]);
        }
    }
}

fn serverOf(comptime O: type) ?[]const u8 {
    comptime {
        const info = @typeInfo(O).@"struct";
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            if (!std.mem.eql(u8, name, "prefix")) continue;
            // A prefix from the config: Docs would fill it in when it
            // serves the document.
            if (!attrs.@"comptime") return null;
            const prefix: []const u8 = attrs.defaultValue(F).?;
            return prefix;
        }
        return null;
    }
}

fn methodName(comptime method: std.http.Method) []const u8 {
    comptime {
        const upper = @tagName(method);
        var out: [upper.len]u8 = undefined;
        for (upper, &out) |c, *slot| slot.* = std.ascii.toLower(c);
        const final = out;
        return &final;
    }
}

fn statusText(comptime status: u16) []const u8 {
    return std.fmt.comptimePrint("{d}", .{status});
}

/// The reason phrase of RFC 9110.
fn reason(comptime status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Response",
    };
}

/// `items` sorted by `less`, stable: a merge sort, n log n comparisons.
fn sorted(comptime Item: type, comptime items: []const Item, comptime less: anytype) []const Item {
    comptime {
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
}

// ------------------------------------------------------------------ the JSON

/// Writes the document through `sink`: `writeAll`, `writeString` (a JSON
/// string, quoted) and `writeInt`. Indented by two spaces, as a file in
/// a repository would be.
fn writeDocument(sink: anytype, doc: *const Document) Error!void {
    var e: Emitter(@TypeOf(sink)) = .{ .sink = sink };
    try e.open("{");
    try e.key("openapi");
    try e.string("3.1.2");
    try e.key("info");
    try e.open("{");
    try e.key("title");
    try e.string(doc.title);
    try e.key("version");
    try e.string(doc.version);
    try e.close("}");
    if (doc.server) |url| {
        try e.key("servers");
        try e.open("[");
        try e.item();
        try e.open("{");
        try e.key("url");
        try e.string(url);
        try e.close("}");
        try e.close("]");
    }
    try e.key("tags");
    try e.open("[");
    for (doc.tags) |*tag| {
        try e.item();
        try e.open("{");
        try e.key("name");
        try e.string(tag.name);
        if (tag.description) |text| {
            try e.key("description");
            try e.string(text);
        }
        try e.close("}");
    }
    try e.close("]");
    try e.key("paths");
    try e.open("{");
    for (doc.paths) |*path| {
        try e.key(path.path);
        try e.open("{");
        for (path.operations) |*operation| {
            try e.key(operation.method);
            try writeOperation(&e, operation);
        }
        try e.close("}");
    }
    try e.close("}");
    try e.key("components");
    try e.open("{");
    try e.key("schemas");
    try e.open("{");
    for (doc.schemas) |*named| {
        try e.key(named.name);
        try writeSchema(&e, &named.schema);
    }
    try e.close("}");
    try e.close("}");
    try e.close("}");
    try e.raw("\n");
}

fn writeOperation(e: anytype, operation: *const Operation) Error!void {
    try e.open("{");
    try e.key("operationId");
    try e.string(operation.operation_id);
    try e.key("tags");
    try e.open("[");
    try e.item();
    try e.string(operation.tag);
    try e.close("]");
    try e.key("summary");
    try e.string(operation.summary);
    if (operation.description) |text| {
        try e.key("description");
        try e.string(text);
    }
    if (operation.parameters.len > 0) {
        try e.key("parameters");
        try e.open("[");
        for (operation.parameters) |*p| {
            try e.item();
            try e.open("{");
            try e.key("name");
            try e.string(p.name);
            try e.key("in");
            try e.string(p.in);
            try e.key("required");
            try e.boolean(p.required);
            if (p.description) |text| {
                try e.key("description");
                try e.string(text);
            }
            if (p.exploded) {
                try e.key("style");
                try e.string("form");
                try e.key("explode");
                try e.boolean(true);
            }
            try e.key("schema");
            try writeSchema(e, &p.schema);
            try e.close("}");
        }
        try e.close("]");
    }
    if (operation.request_body) |*body| {
        try e.key("requestBody");
        try e.open("{");
        try e.key("required");
        try e.boolean(true);
        try e.key("content");
        try writeContent(e, body);
        try e.close("}");
    }
    try e.key("responses");
    try e.open("{");
    for (operation.responses) |*response| {
        try e.key(response.status);
        try e.open("{");
        try e.key("description");
        try e.string(response.description);
        if (response.content) |*content| {
            try e.key("content");
            try writeContent(e, content);
        }
        try e.close("}");
    }
    try e.close("}");
    try e.close("}");
}

fn writeContent(e: anytype, content: *const Content) Error!void {
    try e.open("{");
    try e.key(content.media_type);
    try e.open("{");
    try e.key("schema");
    try writeSchema(e, &content.schema);
    if (content.examples.len > 0) {
        try e.key("examples");
        try e.open("{");
        for (content.examples) |*example| {
            try e.key(example.name);
            try e.open("{");
            try e.key("value");
            try writeValue(e, &example.value);
            try e.close("}");
        }
        try e.close("}");
    }
    try e.close("}");
    try e.close("}");
}

fn writeSchema(e: anytype, s: *const Schema) Error!void {
    try e.open("{");
    if (s.ref) |ref| {
        if (s.nullable) {
            try e.key("oneOf");
            try e.open("[");
            try e.item();
            try e.open("{");
            try e.key("$ref");
            try e.string(ref);
            try e.close("}");
            try e.item();
            try e.open("{");
            try e.key("type");
            try e.string("null");
            try e.close("}");
            try e.close("]");
        } else {
            try e.key("$ref");
            try e.string(ref);
        }
    } else {
        try e.key("type");
        if (s.nullable) {
            try e.open("[");
            try e.item();
            try e.string(s.json_type);
            try e.item();
            try e.string("null");
            try e.close("]");
        } else {
            try e.string(s.json_type);
        }
        if (s.format) |format| {
            try e.key("format");
            try e.string(format);
        }
    }
    if (s.description) |text| {
        try e.key("description");
        try e.string(text);
    }
    for (s.numbers) |*k| {
        try e.key(k.name);
        try e.int(k.value);
    }
    if (s.pattern) |pattern| {
        try e.key("pattern");
        try e.string(pattern);
    }
    if (s.enum_values.len > 0) {
        try e.key("enum");
        try e.open("[");
        for (s.enum_values) |name| {
            try e.item();
            try e.string(name);
        }
        if (s.nullable) {
            try e.item();
            try e.raw("null");
        }
        try e.close("]");
    }
    if (s.default) |*default| {
        try e.key("default");
        try writeValue(e, default);
    }
    if (s.items) |items| {
        try e.key("items");
        try writeSchema(e, items);
    }
    if (s.object) {
        if (s.required.len > 0) {
            try e.key("required");
            try e.open("[");
            for (s.required) |name| {
                try e.item();
                try e.string(name);
            }
            try e.close("]");
        }
        try e.key("properties");
        try e.open("{");
        for (s.properties) |*p| {
            try e.key(p.name);
            try writeSchema(e, &p.schema);
        }
        try e.close("}");
        if (s.closed) {
            try e.key("additionalProperties");
            try e.boolean(false);
        }
    }
    try e.close("}");
}

fn writeValue(e: anytype, value: *const Value) Error!void {
    switch (value.*) {
        .null => try e.raw("null"),
        .bool => |b| try e.boolean(b),
        .int => |n| try e.int(n),
        .string => |text| try e.string(text),
        .array => |items| {
            try e.open("[");
            for (items) |*item| {
                try e.item();
                try writeValue(e, item);
            }
            try e.close("]");
        },
        .object => |members| {
            try e.open("{");
            for (members) |*field| {
                try e.key(field.name);
                try writeValue(e, &field.value);
            }
            try e.close("}");
        },
    }
}

// ------------------------------------------------------------------ the JSON of variant A

// The text of each object and array is what a pure function of its model
// and its depth returns, the same bytes `writeDocument` writes. The
// compiler memoizes such a call: a piece met again, such as a `$ref` or an
// error response that many routes share, costs a lookup. Lists are joined
// in halves, so a byte is copied a few times on its way up; no array is
// written in place.

const Text = []const u8;

fn documentText(comptime doc: Document) Text {
    comptime {
        var members: []const Text = &.{
            member("openapi", quoted("3.1.2")),
            member("info", objectText(1, &.{ member("title", quoted(doc.title)), member("version", quoted(doc.version)) })),
        };
        if (doc.server) |url| members = members ++ &[_]Text{member("servers", arrayText(1, &.{objectText(2, &.{member("url", quoted(url))})}))};
        var tags: [doc.tags.len]Text = undefined;
        for (doc.tags, &tags) |tag, *slot| slot.* = tagText(tag);
        const tag_texts = tags;
        members = members ++ &[_]Text{member("tags", arrayText(1, &tag_texts))};
        var paths: [doc.paths.len]Text = undefined;
        for (doc.paths, &paths) |path, *slot| slot.* = member(path.path, pathText(path));
        const path_texts = paths;
        members = members ++ &[_]Text{member("paths", objectText(1, &path_texts))};
        var schemas: [doc.schemas.len]Text = undefined;
        for (doc.schemas, &schemas) |named, *slot| slot.* = member(named.name, schemaText(named.schema, 3));
        const schema_texts = schemas;
        members = members ++ &[_]Text{member("components", objectText(1, &.{member("schemas", objectText(2, &schema_texts))}))};
        return objectText(0, members) ++ "\n";
    }
}

fn tagText(comptime tag: Tag) Text {
    comptime {
        var members: []const Text = &.{member("name", quoted(tag.name))};
        if (tag.description) |text| members = members ++ &[_]Text{member("description", quoted(text))};
        return objectText(2, members);
    }
}

fn pathText(comptime path: PathItem) Text {
    comptime {
        var operations: [path.operations.len]Text = undefined;
        for (path.operations, &operations) |operation, *slot| slot.* = member(operation.method, operationText(operation, 3));
        const final = operations;
        return objectText(2, &final);
    }
}

fn operationText(comptime operation: Operation, comptime depth: usize) Text {
    comptime {
        var members: []const Text = &.{
            member("operationId", quoted(operation.operation_id)),
            member("tags", arrayText(depth + 1, &.{quoted(operation.tag)})),
            member("summary", quoted(operation.summary)),
        };
        if (operation.description) |text| members = members ++ &[_]Text{member("description", quoted(text))};
        if (operation.parameters.len > 0) {
            var parameters: [operation.parameters.len]Text = undefined;
            for (operation.parameters, &parameters) |p, *slot| slot.* = parameterText(p, depth + 2);
            const final = parameters;
            members = members ++ &[_]Text{member("parameters", arrayText(depth + 1, &final))};
        }
        if (operation.request_body) |body| members = members ++ &[_]Text{member("requestBody", objectText(depth + 1, &.{
            member("required", "true"),
            member("content", contentText(body, depth + 2)),
        }))};
        var responses: [operation.responses.len]Text = undefined;
        for (operation.responses, &responses) |response, *slot| slot.* = member(response.status, responseText(response, depth + 2));
        const final = responses;
        members = members ++ &[_]Text{member("responses", objectText(depth + 1, &final))};
        return objectText(depth, members);
    }
}

fn parameterText(comptime p: Parameter, comptime depth: usize) Text {
    comptime {
        var members: []const Text = &.{
            member("name", quoted(p.name)),
            member("in", quoted(p.in)),
            member("required", if (p.required) "true" else "false"),
        };
        if (p.description) |text| members = members ++ &[_]Text{member("description", quoted(text))};
        if (p.exploded) members = members ++ &[_]Text{ member("style", quoted("form")), member("explode", "true") };
        members = members ++ &[_]Text{member("schema", schemaText(p.schema, depth + 1))};
        return objectText(depth, members);
    }
}

fn responseText(comptime response: Response, comptime depth: usize) Text {
    comptime {
        var members: []const Text = &.{member("description", quoted(response.description))};
        if (response.content) |content| members = members ++ &[_]Text{member("content", contentText(content, depth + 1))};
        return objectText(depth, members);
    }
}

fn contentText(comptime content: Content, comptime depth: usize) Text {
    comptime {
        var inner: []const Text = &.{member("schema", schemaText(content.schema, depth + 2))};
        if (content.examples.len > 0) {
            var examples: [content.examples.len]Text = undefined;
            for (content.examples, &examples) |example, *slot| {
                slot.* = member(example.name, objectText(depth + 3, &.{member("value", valueText(example.value, depth + 4))}));
            }
            const final = examples;
            inner = inner ++ &[_]Text{member("examples", objectText(depth + 2, &final))};
        }
        return objectText(depth, &.{member(content.media_type, objectText(depth + 1, inner))});
    }
}

fn schemaText(comptime s: Schema, comptime depth: usize) Text {
    comptime {
        var members: []const Text = &.{};
        if (s.ref) |ref| {
            members = if (s.nullable) &.{member("oneOf", arrayText(depth + 1, &.{
                objectText(depth + 2, &.{member("$ref", quoted(ref))}),
                objectText(depth + 2, &.{member("type", quoted("null"))}),
            }))} else &.{member("$ref", quoted(ref))};
        } else {
            const type_text = if (s.nullable) arrayText(depth + 1, &.{ quoted(s.json_type), quoted("null") }) else quoted(s.json_type);
            members = &.{member("type", type_text)};
            if (s.format) |format| members = members ++ &[_]Text{member("format", quoted(format))};
        }
        if (s.description) |text| members = members ++ &[_]Text{member("description", quoted(text))};
        for (s.numbers) |k| members = members ++ &[_]Text{member(k.name, decimal(k.value))};
        if (s.pattern) |pattern| members = members ++ &[_]Text{member("pattern", quoted(pattern))};
        if (s.enum_values.len > 0) {
            var values: []const Text = &.{};
            for (s.enum_values) |name| values = values ++ &[_]Text{quoted(name)};
            if (s.nullable) values = values ++ &[_]Text{"null"};
            members = members ++ &[_]Text{member("enum", arrayText(depth + 1, values))};
        }
        if (s.default) |default| members = members ++ &[_]Text{member("default", valueText(default, depth + 1))};
        if (s.items) |items| members = members ++ &[_]Text{member("items", schemaText(items.*, depth + 1))};
        if (s.object) {
            if (s.required.len > 0) {
                var names: []const Text = &.{};
                for (s.required) |name| names = names ++ &[_]Text{quoted(name)};
                members = members ++ &[_]Text{member("required", arrayText(depth + 1, names))};
            }
            var properties: [s.properties.len]Text = undefined;
            for (s.properties, &properties) |p, *slot| slot.* = member(p.name, schemaText(p.schema, depth + 2));
            const final = properties;
            members = members ++ &[_]Text{member("properties", objectText(depth + 1, &final))};
            if (s.closed) members = members ++ &[_]Text{member("additionalProperties", "false")};
        }
        return objectText(depth, members);
    }
}

fn valueText(comptime value: Value, comptime depth: usize) Text {
    comptime {
        switch (value) {
            .null => return "null",
            .bool => |b| return if (b) "true" else "false",
            .int => |n| return decimal(n),
            .string => |text| return quoted(text),
            .array => |items| {
                var texts: [items.len]Text = undefined;
                for (items, &texts) |item, *slot| slot.* = valueText(item, depth + 1);
                const final = texts;
                return arrayText(depth, &final);
            },
            .object => |fields| {
                var texts: [fields.len]Text = undefined;
                for (fields, &texts) |field, *slot| slot.* = member(field.name, valueText(field.value, depth + 1));
                const final = texts;
                return objectText(depth, &final);
            },
        }
    }
}

fn member(comptime key: Text, comptime value: Text) Text {
    return quoted(key) ++ ": " ++ value;
}

/// An object at `depth`: its members a line each, one level deeper.
fn objectText(comptime depth: usize, comptime members: []const Text) Text {
    return enclosed("{", "}", depth, members);
}

fn arrayText(comptime depth: usize, comptime items: []const Text) Text {
    return enclosed("[", "]", depth, items);
}

fn enclosed(comptime open: Text, comptime close: Text, comptime depth: usize, comptime items: []const Text) Text {
    comptime {
        if (items.len == 0) return open ++ close;
        return open ++ breaks[0 .. 3 + 2 * depth] ++ joined(comma_breaks[0 .. 4 + 2 * depth], items) ++ breaks[0 .. 1 + 2 * depth] ++ close;
    }
}

/// `items` with `separator` between them, joined in halves.
fn joined(comptime separator: Text, comptime items: []const Text) Text {
    comptime {
        if (items.len == 1) return items[0];
        const half = items.len / 2;
        return joined(separator, items[0..half]) ++ separator ++ joined(separator, items[half..]);
    }
}

const max_depth = 32;

/// A line break and the indent of each depth: `breaks[0 .. 1 + 2 * depth]`.
const breaks: [1 + 2 * max_depth]u8 = blk: {
    var text: [1 + 2 * max_depth]u8 = @splat(' ');
    text[0] = '\n';
    break :blk text;
};

/// The same after a comma.
const comma_breaks: [2 + 2 * max_depth]u8 = blk: {
    var text: [2 + 2 * max_depth]u8 = @splat(' ');
    text[0] = ',';
    text[1] = '\n';
    break :blk text;
};

/// Objects, arrays and their members, through a sink.
fn Emitter(comptime Sink: type) type {
    return struct {
        sink: Sink,
        depth: usize = 0,
        /// Nothing has been written in the current object or array yet.
        first: bool = true,

        const Self = @This();

        fn line(e: *Self) Error!void {
            const text: []const u8 = if (e.first) breaks[0 .. 1 + 2 * e.depth] else comma_breaks[0 .. 2 + 2 * e.depth];
            e.first = false;
            try e.sink.writeAll(text);
        }

        fn open(e: *Self, bracket: []const u8) Error!void {
            try e.sink.writeAll(bracket);
            e.depth += 1;
            e.first = true;
        }

        fn close(e: *Self, bracket: []const u8) Error!void {
            e.depth -= 1;
            if (!e.first) try e.sink.writeAll(breaks[0 .. 1 + 2 * e.depth]);
            try e.sink.writeAll(bracket);
            e.first = false;
        }

        fn key(e: *Self, name: []const u8) Error!void {
            try e.line();
            try e.sink.writeString(name);
            try e.sink.writeAll(": ");
        }

        fn item(e: *Self) Error!void {
            try e.line();
        }

        fn string(e: *Self, text: []const u8) Error!void {
            try e.sink.writeString(text);
        }

        fn int(e: *Self, value: i64) Error!void {
            try e.sink.writeInt(value);
        }

        fn boolean(e: *Self, value: bool) Error!void {
            try e.sink.writeAll(if (value) "true" else "false");
        }

        fn raw(e: *Self, text: []const u8) Error!void {
            try e.sink.writeAll(text);
        }
    };
}

/// The first pass of `render`: the length of the document.
const Counter = struct {
    len: usize = 0,

    fn writeAll(c: *Counter, bytes: []const u8) Error!void {
        c.len += bytes.len;
    }

    fn writeString(c: *Counter, text: []const u8) Error!void {
        c.len += quoted(text).len;
    }

    fn writeInt(c: *Counter, value: i64) Error!void {
        c.len += decimal(value).len;
    }
};

/// The second pass: the array of the length the first found, filled.
const Filler = struct {
    buf: []u8,
    end: usize = 0,

    fn writeAll(f: *Filler, bytes: []const u8) Error!void {
        @memcpy(f.buf[f.end..][0..bytes.len], bytes);
        f.end += bytes.len;
    }

    fn writeString(f: *Filler, text: []const u8) Error!void {
        return f.writeAll(quoted(text));
    }

    fn writeInt(f: *Filler, value: i64) Error!void {
        return f.writeAll(decimal(value));
    }
};

/// The naive way: every piece appended with `++`.
const Appender = struct {
    text: []const u8 = "",

    fn writeAll(a: *Appender, bytes: []const u8) Error!void {
        a.text = a.text ++ bytes;
    }

    fn writeString(a: *Appender, text: []const u8) Error!void {
        a.text = a.text ++ quoted(text);
    }

    fn writeInt(a: *Appender, value: i64) Error!void {
        a.text = a.text ++ decimal(value);
    }
};

/// `text` as a JSON string, quotes included. A pure function of a string,
/// so the compiler runs it once for each distinct one.
fn quoted(comptime text: []const u8) []const u8 {
    comptime {
        for (text) |c| {
            if (c == '"' or c == '\\' or c < 0x20) break;
        } else return "\"" ++ text ++ "\"";
        var out: []const u8 = "\"";
        for (text) |c| out = out ++ escaped(c);
        return out ++ "\"";
    }
}

fn escaped(comptime c: u8) []const u8 {
    return switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => if (c < 0x20) std.fmt.comptimePrint("\\u{x:0>4}", .{c}) else &[_]u8{c},
    };
}

fn decimal(comptime value: i64) []const u8 {
    return std.fmt.comptimePrint("{d}", .{value});
}

/// The sink of `write`, at run time; it escapes as `quoted` does.
const Stream = struct {
    w: *std.Io.Writer,

    fn writeAll(s: *Stream, bytes: []const u8) Error!void {
        return s.w.writeAll(bytes);
    }

    fn writeString(s: *Stream, text: []const u8) Error!void {
        try s.w.writeByte('"');
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (c != '"' and c != '\\' and c >= 0x20) continue;
            try s.w.writeAll(text[start..i]);
            switch (c) {
                '"' => try s.w.writeAll("\\\""),
                '\\' => try s.w.writeAll("\\\\"),
                '\n' => try s.w.writeAll("\\n"),
                '\r' => try s.w.writeAll("\\r"),
                '\t' => try s.w.writeAll("\\t"),
                else => try s.w.print("\\u{x:0>4}", .{c}),
            }
            start = i + 1;
        }
        try s.w.writeAll(text[start..]);
        try s.w.writeByte('"');
    }

    fn writeInt(s: *Stream, value: i64) Error!void {
        return s.w.print("{d}", .{value});
    }
};
