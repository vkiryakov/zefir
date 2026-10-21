//! The JSON Schema of the values of a type, as zefir-http reads and writes
//! them: on input as `ctx.json` and `ctx.form` read a body and the strings
//! of the path, the query, the headers and the cookies fill a DTO; on
//! output as a response writes a value. A schema follows that codec, not
//! the Zig type: a field with a default is not required on input, every
//! field is written on output, `null` included, and a union is an object of
//! one key.
//!
//! A `Registry` collects the types of a document, the ways they go and the
//! types inside them, then gives each named struct, enum and union a schema
//! of its own in `components`, which the other schemas refer to with
//! `$ref`; anonymous types stand inline.
const std = @import("std");
const http = @import("http");
const v = @import("validator");
const json = @import("json.zig");
const example = @import("example.zig");
const root = @import("root.zig");

/// The way values of a type go: read from a request, or written in a
/// response.
pub const Direction = enum { input, output };

/// A type of the document and the way its values go.
pub const Use = struct {
    T: type,
    direction: Direction,
    /// Written inside the body of an `http.Problem`, which leaves out its
    /// null fields.
    problem: bool = false,
};

/// How the values of a schema are read or written.
const Mode = enum {
    /// Read: a `?T` field may be absent or null, a field with a default may
    /// be absent, unknown keys go by the policy of the struct.
    input,
    /// Written, every field, `null` included.
    output,
    /// Written inside the body of an `http.Problem`: a null field is left
    /// out, so a `?T` field is not required and never null.
    problem,
    /// Written both ways: a `?T` field is not required and may be null.
    both,
};

fn modeOf(comptime u: Use) Mode {
    return switch (u.direction) {
        .input => .input,
        .output => if (u.problem) .problem else .output,
    };
}

/// The types of a document. `use` each type the document shows, `finish`
/// once, then `schema` gives the schema of a use, and `components` the
/// schemas of the named types.
pub const Registry = struct {
    /// What happens to the unknown keys of a body whose DTO does not say it
    /// itself: the server's `.unknown_fields.body`.
    body_policy: http.UnknownFields,
    /// The named types met, in the order met; after `finish`, by name.
    entries: []const Entry = &.{},
    finished: bool = false,

    /// A named type and the ways its values go.
    const Entry = struct {
        T: type,
        input: bool = false,
        output: bool = false,
        problem: bool = false,
        /// The name of its schema, given by `finish`.
        name: []const u8 = "",

        /// How its values are written.
        fn outputMode(e: Entry) Mode {
            if (e.output and e.problem) return .both;
            return if (e.problem) .problem else .output;
        }

        /// The mode of its one schema.
        fn onlyMode(e: Entry) Mode {
            return if (e.output or e.problem) e.outputMode() else .input;
        }
    };

    pub fn init(comptime body_policy: http.UnknownFields) Registry {
        return .{ .body_policy = body_policy };
    }

    /// Records the use `u`, and the types inside `u.T`.
    pub fn use(comptime r: *Registry, comptime u: Use) void {
        comptime {
            @setEvalBranchQuota(quota);
            if (r.finished) @compileError("zefir.openapi: internal: Registry.use after finish");
            r.mark(u.T, modeOf(u), &.{});
        }
    }

    /// Names the schemas.
    pub fn finish(comptime r: *Registry) void {
        comptime {
            @setEvalBranchQuota(quota);
            var entries = r.entries[0..r.entries.len].*;
            for (&entries) |*e| e.name = baseName(e.T);
            const final = entries;
            r.entries = &final;
            r.finished = true;
        }
    }

    /// The schema of the use `u`: a `$ref` to the schema of a named type,
    /// else the schema itself.
    pub fn schema(comptime r: *const Registry, comptime u: Use) json.Node {
        comptime {
            @setEvalBranchQuota(quota);
            if (!r.finished) @compileError("zefir.openapi: internal: Registry.schema before finish");
            return node(r.typeParts(u.T, modeOf(u), false, typeName(u.T), &.{}));
        }
    }

    /// The `schemas` of the document's `components`.
    pub fn components(comptime r: *const Registry) json.Node {
        comptime {
            @setEvalBranchQuota(quota);
            if (!r.finished) @compileError("zefir.openapi: internal: Registry.components before finish");
            var members: []const json.Member = &.{};
            for (r.entries) |e| {
                members = members ++ [_]json.Member{.{ .key = e.name, .value = node(r.componentParts(e, e.onlyMode())) }};
            }
            return .{ .object = members };
        }
    }

    /// Marks `T`, used in `mode`, and the types inside it. `stack` holds
    /// the types `T` is inside of, so that an anonymous type that holds
    /// itself stops.
    fn mark(comptime r: *Registry, comptime T: type, comptime mode: Mode, comptime stack: []const type) void {
        if (T == std.json.Value) return;
        switch (@typeInfo(T)) {
            .optional => |o| r.mark(o.child, mode, stack),
            .pointer => |p| if (!isString(T)) r.mark(p.child, mode, stack),
            .array => |a| if (a.child != u8) r.mark(a.child, mode, stack),
            .@"struct" => |s| {
                if (s.is_tuple) {
                    for (s.field_types) |F| r.mark(F, mode, stack);
                    return;
                }
                if (!r.enter(T, mode, stack)) return;
                const inner = stack ++ [_]type{T};
                if (mode != .input and root.writesItself(T)) return r.mark(asOf(T), mode, inner);
                for (s.field_types, s.field_attrs) |F, attrs| {
                    if (F == void or (mode == .input and attrs.@"comptime")) continue;
                    r.mark(F, mode, inner);
                }
            },
            .@"union" => |u| {
                if (!r.enter(T, mode, stack)) return;
                const inner = stack ++ [_]type{T};
                if (root.writesItself(T)) return r.mark(asOf(T), mode, inner);
                for (u.field_types) |F| {
                    if (F != void) r.mark(F, mode, inner);
                }
            },
            .@"enum" => {
                if (!r.enter(T, mode, stack)) return;
                if (mode != .input and root.writesItself(T)) r.mark(asOf(T), mode, stack ++ [_]type{T});
            },
            else => {},
        }
    }

    /// Records that `T` is used in `mode`; true when that is new, and the
    /// types inside `T` are to be marked in `mode` too.
    fn enter(comptime r: *Registry, comptime T: type, comptime mode: Mode, comptime stack: []const type) bool {
        if (!isNamed(T)) {
            for (stack) |S| {
                if (S == T) return false;
            }
            return true;
        }
        for (r.entries, 0..) |e, i| {
            if (e.T != T) continue;
            if (hasMode(e, mode)) return false;
            var entries = r.entries[0..r.entries.len].*;
            setMode(&entries[i], mode);
            const final = entries;
            r.entries = &final;
            return true;
        }
        var e: Entry = .{ .T = T };
        setMode(&e, mode);
        r.entries = r.entries ++ [_]Entry{e};
        return true;
    }

    fn hasMode(comptime e: Entry, comptime mode: Mode) bool {
        return switch (mode) {
            .input => e.input,
            .output => e.output,
            .problem => e.problem,
            .both => e.output and e.problem,
        };
    }

    fn setMode(comptime e: *Entry, comptime mode: Mode) void {
        switch (mode) {
            .input => e.input = true,
            .output => e.output = true,
            .problem => e.problem = true,
            .both => {
                e.output = true;
                e.problem = true;
            },
        }
    }

    fn entryOf(comptime r: *const Registry, comptime T: type) ?Entry {
        for (r.entries) |e| {
            if (e.T == T) return e;
        }
        return null;
    }

    /// The name a `$ref` in `mode` takes to the schema of `e`.
    fn refName(comptime e: Entry, comptime mode: Mode) []const u8 {
        _ = mode;
        return e.name;
    }

    /// The schema of the named type of `e`, in `mode`.
    fn componentParts(comptime r: *const Registry, comptime e: Entry, comptime mode: Mode) Parts {
        return bodyParts(r, e.T, mode, false, typeName(e.T), &.{});
    }

    /// The schema of a value of `T` in `mode`; `nullable` adds `null`.
    /// `where` names the value in a message.
    fn typeParts(comptime r: ?*const Registry, comptime T: type, comptime mode: Mode, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type) Parts {
        // Any JSON, null too.
        if (T == std.json.Value) return .{};
        switch (@typeInfo(T)) {
            .optional => |o| return typeParts(r, o.child, mode, true, where, stack),
            .bool => return .{ .kind = typeKind("boolean", nullable) },
            .int => |i| return intParts(T, i, nullable),
            .float => |f| if (f.bits <= 64) return .{ .kind = typeKind("number", nullable) ++ formatOf(switch (f.bits) {
                32 => "float",
                64 => "double",
                else => null,
            }) },
            .pointer => |p| switch (p.size) {
                .one => return typeParts(r, p.child, mode, nullable, where, stack),
                .slice, .many => if (isString(T)) {
                    return .{ .kind = typeKind("string", nullable) };
                } else if (p.size == .slice) {
                    const item = typeParts(r, p.child, mode, false, where ++ "[]", stack);
                    return .{ .kind = typeKind("array", nullable), .items = &item };
                },
                .c => {},
            },
            .array => |a| {
                if (a.child == u8) return .{ .kind = typeKind("string", nullable), .keywords = &.{count("maxLength", a.len)} };
                const item = typeParts(r, a.child, mode, false, where ++ "[]", stack);
                return .{ .kind = typeKind("array", nullable), .keywords = &.{ count("minItems", a.len), count("maxItems", a.len) }, .items = &item };
            },
            .@"struct" => |s| {
                if (s.is_tuple) {
                    var prefix: [s.field_types.len]json.Node = undefined;
                    for (s.field_types, &prefix, 0..) |F, *item, i| item.* = node(typeParts(r, F, mode, false, std.fmt.comptimePrint("{s}[{d}]", .{ where, i }), stack));
                    const final = prefix;
                    return .{ .kind = typeKind("array", nullable), .keywords = &.{
                        .{ .key = "prefixItems", .value = .{ .array = &final } },
                        count("minItems", final.len),
                        count("maxItems", final.len),
                    } };
                }
                return namedParts(r, T, mode, nullable, where, stack);
            },
            .@"union" => |u| if (u.tag_type != null) return namedParts(r, T, mode, nullable, where, stack),
            .@"enum" => return namedParts(r, T, mode, nullable, where, stack),
            else => {},
        }
        @compileError("zefir.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " has no JSON Schema: a value of the document is a bool, an integer, " ++
            "a float of up to 64 bits, an enum, a string, a struct, a union(enum), a slice, an array, a tuple or ?T of them");
    }

    /// A `$ref` to the schema of the named type `T`, or its schema inline
    /// for an anonymous one.
    fn namedParts(comptime r: ?*const Registry, comptime T: type, comptime mode: Mode, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type) Parts {
        if (r) |registry| if (registry.entryOf(T)) |e| return refParts(refName(e, mode), nullable);
        for (stack) |S| {
            if (S == T) @compileError("zefir.openapi: " ++ where ++ ": the anonymous type " ++ @typeName(T) ++ " holds itself, which an inline schema cannot; give it a name, such as const Node = struct { ... }");
        }
        return bodyParts(r, T, mode, nullable, where, stack);
    }

    /// The schema of a struct, an enum or a union `T` itself.
    fn bodyParts(comptime r: ?*const Registry, comptime T: type, comptime mode: Mode, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type) Parts {
        if (mode != .input and root.writesItself(T)) {
            var p = typeParts(r, asOf(T), mode, nullable, where, stack ++ [_]type{T});
            p.description = typeTexts(T);
            p.deprecated = typeDeprecated(T);
            return p;
        }
        return switch (@typeInfo(T)) {
            .@"struct" => structParts(r, T, mode, nullable, stack),
            .@"enum" => enumParts(T, mode, nullable),
            .@"union" => unionParts(r, T, mode, nullable, stack),
            else => unreachable,
        };
    }

    fn structParts(comptime r: ?*const Registry, comptime T: type, comptime mode: Mode, comptime nullable: bool, comptime stack: []const type) Parts {
        const s = @typeInfo(T).@"struct";
        const inner = stack ++ [_]type{T};
        var properties: []const json.Member = &.{};
        var required: []const []const u8 = &.{};
        for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
            if (F == void or (mode == .input and attrs.@"comptime")) continue;
            const key = v.nameOf(T, @field(std.meta.FieldEnum(T), name));
            properties = properties ++ [_]json.Member{.{ .key = key, .value = node(fieldParts(r, T, name, F, attrs, mode, inner)) }};
            const needed = switch (mode) {
                .input => @typeInfo(F) != .optional and attrs.default_value_ptr == null,
                .output => true,
                .problem, .both => @typeInfo(F) != .optional,
            };
            if (needed) required = required ++ [_][]const u8{key};
        }
        return .{
            .kind = typeKind("object", nullable),
            .description = typeTexts(T),
            .deprecated = typeDeprecated(T),
            .required = required,
            .properties = properties,
            .closed = mode == .input and policyOf(T, r) == .reject,
        };
    }

    /// The schema of the field `name` of `T`, of type `F`.
    fn fieldParts(comptime r: ?*const Registry, comptime T: type, comptime name: []const u8, comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime mode: Mode, comptime stack: []const type) Parts {
        const where = typeName(T) ++ "." ++ name;
        // Inside a problem a null field is left out: when there, it is not
        // null.
        const Value = if (mode == .problem and @typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        var p = typeParts(r, Value, mode, false, where, stack);
        if (attrs.@"comptime") p.keywords = [_]json.Member{.{ .key = "const", .value = example.value(F, attrs.defaultValue(F).?, false, where) }} ++ p.keywords;
        const doc = fieldDocOf(T, name);
        if (doc.description) |text| p.description = &.{text};
        p.deprecated = doc.deprecated;
        if (mode == .input and !root.writesItself(F)) {
            if (attrs.defaultValue(F)) |default| p.default = example.value(F, default, false, where);
        }
        return p;
    }

    fn enumParts(comptime T: type, comptime mode: Mode, comptime nullable: bool) Parts {
        const e = @typeInfo(T).@"enum";
        var names: []const json.Node = &.{};
        for (e.field_names) |name| names = names ++ [_]json.Node{.{ .string = name }};
        // A value without a name is written as its integer.
        if (mode != .input and e.mode == .nonexhaustive) {
            const named = json.object(&.{ .{ .key = "type", .value = .{ .string = "string" } }, .{ .key = "enum", .value = .{ .array = names } } });
            const number = json.object(&.{.{ .key = "type", .value = .{ .string = "integer" } }});
            const ways: []const json.Node = if (nullable) &.{ named, number, null_schema } else &.{ named, number };
            return .{ .kind = &.{.{ .key = "anyOf", .value = .{ .array = ways } }}, .description = typeTexts(T), .deprecated = typeDeprecated(T) };
        }
        if (nullable) names = names ++ [_]json.Node{.null};
        return .{
            .kind = typeKind("string", nullable),
            .description = typeTexts(T),
            .deprecated = typeDeprecated(T),
            .keywords = &.{.{ .key = "enum", .value = .{ .array = names } }},
        };
    }

    /// A union: an object of one key, its active variant.
    fn unionParts(comptime r: ?*const Registry, comptime T: type, comptime mode: Mode, comptime nullable: bool, comptime stack: []const type) Parts {
        const u = @typeInfo(T).@"union";
        const inner = stack ++ [_]type{T};
        var variants: []const json.Node = &.{};
        for (u.field_names, u.field_types) |name, P| {
            var payload: Parts = if (P == void)
                .{ .kind = typeKind("object", false), .keywords = &.{count("maxProperties", 0)} }
            else
                typeParts(r, P, mode, false, typeName(T) ++ "." ++ name, inner);
            const doc = fieldDocOf(T, name);
            if (doc.description) |text| payload.description = &.{text};
            payload.deprecated = doc.deprecated;
            variants = variants ++ [_]json.Node{node(.{
                .kind = typeKind("object", false),
                .required = &.{name},
                .properties = &.{.{ .key = name, .value = node(payload) }},
                .closed = true,
            })};
        }
        if (nullable) variants = variants ++ [_]json.Node{null_schema};
        return .{ .kind = &.{.{ .key = "oneOf", .value = .{ .array = variants } }}, .description = typeTexts(T), .deprecated = typeDeprecated(T) };
    }
};

/// A schema in the making, its members by what they say; `node` puts them
/// in their order.
const Parts = struct {
    /// What the value is: `type` and `format`, a `$ref`, or `oneOf` or
    /// `anyOf` of what it may be.
    kind: []const json.Member = &.{},
    /// Sentences of the description, joined by spaces.
    description: []const []const u8 = &.{},
    deprecated: bool = false,
    /// The keywords of the type (`enum`, `const`, bounds), then those of
    /// its rules.
    keywords: []const json.Member = &.{},
    default: ?json.Node = null,
    /// The schema of the items of a list.
    items: ?*const Parts = null,
    required: []const []const u8 = &.{},
    /// The properties of an object.
    properties: ?[]const json.Member = null,
    /// `additionalProperties: false`.
    closed: bool = false,
    examples: []const json.Node = &.{},
};

/// The schema of `p`: `kind`, `description`, `deprecated`, the keywords,
/// `default`, `items`, `required`, `properties`, `additionalProperties`
/// and `examples`, in this order.
fn node(comptime p: Parts) json.Node {
    var m: []const json.Member = p.kind;
    if (p.description.len > 0) m = m ++ [_]json.Member{.{ .key = "description", .value = .{ .string = joined(p.description) } }};
    if (p.deprecated) m = m ++ [_]json.Member{.{ .key = "deprecated", .value = .{ .boolean = true } }};
    m = m ++ p.keywords;
    if (p.default) |default| m = m ++ [_]json.Member{.{ .key = "default", .value = default }};
    if (p.items) |items| m = m ++ [_]json.Member{.{ .key = "items", .value = node(items.*) }};
    if (p.required.len > 0) {
        var names: [p.required.len]json.Node = undefined;
        for (p.required, &names) |name, *n| n.* = .{ .string = name };
        const final = names;
        m = m ++ [_]json.Member{.{ .key = "required", .value = .{ .array = &final } }};
    }
    if (p.properties) |properties| m = m ++ [_]json.Member{.{ .key = "properties", .value = .{ .object = properties } }};
    if (p.closed) m = m ++ [_]json.Member{.{ .key = "additionalProperties", .value = .{ .boolean = false } }};
    if (p.examples.len > 0) m = m ++ [_]json.Member{.{ .key = "examples", .value = .{ .array = p.examples } }};
    return .{ .object = m };
}

fn joined(comptime sentences: []const []const u8) []const u8 {
    var out: []const u8 = sentences[0];
    for (sentences[1..]) |s| out = out ++ " " ++ s;
    return out;
}

const null_schema = json.object(&.{.{ .key = "type", .value = .{ .string = "null" } }});

/// `type`, with `null` too when `nullable`.
fn typeKind(comptime name: []const u8, comptime nullable: bool) []const json.Member {
    const value: json.Node = if (nullable) .{ .array = &.{ .{ .string = name }, .{ .string = "null" } } } else .{ .string = name };
    return &.{.{ .key = "type", .value = value }};
}

fn formatOf(comptime format: ?[]const u8) []const json.Member {
    const name = format orelse return &.{};
    return &.{.{ .key = "format", .value = .{ .string = name } }};
}

/// A keyword with a number.
fn count(comptime key: []const u8, comptime n: comptime_int) json.Member {
    return .{ .key = key, .value = .{ .raw = std.fmt.comptimePrint("{d}", .{n}) } };
}

/// A `$ref` to the schema `name`; with `nullable`, `oneOf` it and `null`.
fn refParts(comptime name: []const u8, comptime nullable: bool) Parts {
    const ref = json.object(&.{.{ .key = "$ref", .value = .{ .string = "#/components/schemas/" ++ name } }});
    if (!nullable) return .{ .kind = ref.object };
    return .{ .kind = &.{.{ .key = "oneOf", .value = .{ .array = &.{ ref, null_schema } } }} };
}

/// An integer: its `format` from the registry of OpenAPI, and its bounds
/// up to 32 bits; a wider one has only `minimum: 0` when unsigned, since
/// tools in JavaScript read numbers beyond 2^53 inexactly. `usize` and
/// `isize` have no format: their size is the target's.
fn intParts(comptime T: type, comptime i: std.lang.Type.Int, comptime nullable: bool) Parts {
    const sized = T != usize and T != isize;
    const prefix = if (i.signedness == .signed) "int" else "uint";
    const format: ?[]const u8 = switch (i.bits) {
        8, 16, 32, 64 => if (sized) std.fmt.comptimePrint("{s}{d}", .{ prefix, i.bits }) else null,
        else => null,
    };
    const keywords: []const json.Member = if (sized and i.bits <= 32)
        &.{ count("minimum", std.math.minInt(T)), count("maximum", std.math.maxInt(T)) }
    else if (i.signedness == .unsigned)
        &.{count("minimum", 0)}
    else
        &.{};
    return .{ .kind = typeKind("integer", nullable) ++ formatOf(format), .keywords = keywords };
}

/// A string: bytes, of a slice or of a many-item pointer with a sentinel.
fn isString(comptime T: type) bool {
    const p = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return p.child == u8 and (p.size == .slice or (p.size == .many and p.sentinel() != null));
}

/// What happens to the unknown keys of a struct `T` read from a body: its
/// own `unknown_fields`, else the server's.
fn policyOf(comptime T: type, comptime r: ?*const Registry) http.UnknownFields {
    if (@hasDecl(T, "unknown_fields")) return @as(http.UnknownFields, T.unknown_fields);
    return if (r) |registry| registry.body_policy else .reject;
}

/// The `openapi` of `T`, null without one; one of another type stops the
/// build.
fn docOf(comptime T: type) ?root.Doc(T) {
    if (!@hasDecl(T, "openapi")) return null;
    if (@TypeOf(T.openapi) != root.Doc(T))
        @compileError("zefir.openapi: " ++ typeName(T) ++ ".openapi must be of type zefir.openapi.Doc(" ++ typeName(T) ++ ")");
    return T.openapi;
}

/// The texts of the field `name` of `T`, `.{}` when it has none.
fn fieldDocOf(comptime T: type, comptime name: []const u8) root.FieldDoc(@FieldType(T, name)) {
    const doc = docOf(T) orelse return .{};
    if (!@hasField(@TypeOf(doc), "fields")) return .{};
    return @field(doc.fields, name);
}

/// The sentences of the description of `T` itself.
fn typeTexts(comptime T: type) []const []const u8 {
    const doc = docOf(T) orelse return &.{};
    return if (doc.description) |text| &.{text} else &.{};
}

fn typeDeprecated(comptime T: type) bool {
    const doc = docOf(T) orelse return false;
    return doc.deprecated;
}

/// The type whose JSON a type that writes itself writes: its `Doc(T).as`.
fn asOf(comptime T: type) type {
    const doc = docOf(T) orelse @compileError("zefir.openapi: " ++ typeName(T) ++ " writes itself with jsonStringify, so the document does not know its JSON; " ++
        "say what it looks like: pub const openapi: zefir.openapi.Doc(" ++ typeName(T) ++ ") = .{ .as = []const u8 }");
    return doc.as;
}

/// A type with a schema of its own in `components`: a struct, an enum or a
/// union with a name, or with a `.name` in its `Doc`. An anonymous type,
/// named by the compiler with a number that changes as the program does,
/// stands inline.
fn isNamed(comptime T: type) bool {
    if (docOf(T)) |doc| if (doc.name != null) return true;
    return !isAnonymous(T);
}

/// The compiler names an anonymous type after its place and a number:
/// `dto.Order__struct_931`.
fn isAnonymous(comptime T: type) bool {
    const name = shortName(@typeName(T));
    const at = std.mem.lastIndexOf(u8, name, "__") orelse return false;
    const rest = name[at + 2 ..];
    for ([_][]const u8{ "struct_", "union_", "enum_", "opaque_" }) |kind| {
        if (!std.mem.startsWith(u8, rest, kind) or rest.len == kind.len) continue;
        for (rest[kind.len..]) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else return true;
    }
    return false;
}

/// The name of the schema of `T`: its `Doc(T).name`, else the last part of
/// its name.
fn baseName(comptime T: type) []const u8 {
    if (docOf(T)) |doc| if (doc.name) |name| return name;
    return shortName(@typeName(T));
}

/// How messages name `T`: the last part of its name.
pub fn typeName(comptime T: type) []const u8 {
    if (T == http.Problem) return "http.Problem";
    return shortName(@typeName(T));
}

/// The last part of a type's name, outside parentheses:
/// "dto.TodoResponse" is "TodoResponse", "dto.Page(dto.Todo)" is
/// "Page(dto.Todo)".
fn shortName(comptime full: []const u8) []const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return full[start..];
}

/// The eval branch quota of a call of the registry: the validator raises
/// it as much for each rule it maps.
const quota = 10_000_000;

test {
    _ = @import("tests/schema_test.zig");
}
