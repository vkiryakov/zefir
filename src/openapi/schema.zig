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
const declarations = @import("openapi.zig");

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

/// How the examples and defaults of a schema in `mode` go: one written
/// both ways shows them written with their nulls.
fn wayOf(comptime mode: Mode) example.Way {
    return switch (mode) {
        .input => .input,
        .output, .both => .output,
        .problem => .problem,
    };
}

/// The types of a document. `use` each type the document shows, `finish`
/// once, then `schema` gives the schema of a use, and `components` the
/// schemas of the named types.
pub const Registry = struct {
    /// What happens to the unknown keys of a body whose DTO does not say it
    /// itself: the server's `.unknown_fields.body`.
    body_policy: http.UnknownFields,
    /// The named types met, in the order met.
    entries: []const Entry = &.{},
    /// The schemas of `components`, by name: one for each entry, two for an
    /// entry whose schemas differ both ways.
    schemas: []const Schema = &.{},
    finished: bool = false,

    /// A named type and the ways its values go.
    const Entry = struct {
        T: type,
        input: bool = false,
        output: bool = false,
        problem: bool = false,
        /// The name of its schema, given by `finish`.
        name: []const u8 = "",
        /// Read and written, it has two schemas, which differ:
        /// `<name>-Input` and `<name>-Output`.
        split: bool = false,

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

    /// A schema of `components`: its name, its type and how its values go.
    const Schema = struct { name: []const u8, T: type, mode: Mode };

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

    /// Names the schemas. A type read and written whose two schemas differ
    /// gets both, `<name>-Input` and `<name>-Output`, and so does a type
    /// whose schemas differ only by the names of the schemas they refer to.
    /// A name that is not one, and two types of one name, stop the build.
    pub fn finish(comptime r: *Registry) void {
        comptime {
            @setEvalBranchQuota(quota);
            var named = r.entries[0..r.entries.len].*;
            for (&named) |*e| e.name = checkedName(e.T);
            const with_names = named;
            r.entries = &with_names;
            r.finished = true;
            // A split changes the references to the type, and so maybe the
            // schemas of the types that refer to it: again, until none
            // changes.
            while (true) {
                var next = r.entries[0..r.entries.len].*;
                var changed = false;
                for (&next, r.entries) |*e, now| {
                    if (now.split or !now.input or !(now.output or now.problem)) continue;
                    const read = node(r.componentParts(now, .input));
                    const written = node(r.componentParts(now, now.outputMode()));
                    if (json.eql(read, written)) continue;
                    e.split = true;
                    changed = true;
                }
                const final = next;
                r.entries = &final;
                if (!changed) break;
            }
            var schemas: []const Schema = &.{};
            for (r.entries) |e| {
                if (e.split) {
                    schemas = schemas ++ [_]Schema{
                        .{ .name = e.name ++ "-Input", .T = e.T, .mode = .input },
                        .{ .name = e.name ++ "-Output", .T = e.T, .mode = e.outputMode() },
                    };
                } else {
                    schemas = schemas ++ [_]Schema{.{ .name = e.name, .T = e.T, .mode = e.onlyMode() }};
                }
            }
            const by_name = sorted(Schema, schemas, lessName);
            for (by_name[0..by_name.len -| 1], by_name[@min(1, by_name.len)..]) |a, b| {
                if (std.mem.eql(u8, a.name, b.name))
                    @compileError("zefir.openapi: " ++ @typeName(a.T) ++ " and " ++ @typeName(b.T) ++ " have one schema name, " ++ a.name ++
                        "; give one of them another: pub const openapi: zefir.openapi.Doc(@This()) = .{ .name = \"...\" }");
            }
            r.schemas = by_name;
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
            var members: [r.schemas.len]json.Member = undefined;
            for (r.schemas, &members) |sch, *m| m.* = .{ .key = sch.name, .value = node(r.componentParts(r.entryOf(sch.T).?, sch.mode)) };
            const final = members;
            return .{ .object = &final };
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
                if (mode != .input and declarations.writesItself(T)) return r.mark(asOf(T), mode, inner);
                for (s.field_types, s.field_attrs) |F, attrs| {
                    if (F == void or (mode == .input and attrs.@"comptime")) continue;
                    r.mark(F, mode, inner);
                }
            },
            .@"union" => |u| {
                if (!r.enter(T, mode, stack)) return;
                const inner = stack ++ [_]type{T};
                if (declarations.writesItself(T)) return r.mark(asOf(T), mode, inner);
                for (u.field_types) |F| {
                    if (F != void) r.mark(F, mode, inner);
                }
            },
            .@"enum" => {
                if (!r.enter(T, mode, stack)) return;
                if (mode != .input and declarations.writesItself(T)) r.mark(asOf(T), mode, stack ++ [_]type{T});
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
        if (!e.split) return e.name;
        return e.name ++ if (mode == .input) "-Input" else "-Output";
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
                // An empty tuple is an empty array: prefixItems takes one
                // schema at least.
                if (s.is_tuple and s.field_types.len == 0) return .{ .kind = typeKind("array", nullable), .keywords = &.{count("maxItems", 0)} };
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
        if (mode != .input and declarations.writesItself(T)) {
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
            .description = typeTexts(T) ++ selfNote(T),
            .deprecated = typeDeprecated(T),
            .required = required,
            .properties = properties,
            .closed = mode == .input and policyOf(T, r) == .reject,
            .examples = typeExamples(T, wayOf(mode)),
        };
    }

    /// The schema of the field `name` of `T`, of type `F`.
    fn fieldParts(comptime r: ?*const Registry, comptime T: type, comptime name: []const u8, comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime mode: Mode, comptime stack: []const type) Parts {
        const where = typeName(T) ++ "." ++ name;
        // Inside a problem a null field is left out: when there, it is not
        // null.
        const Value = if (mode == .problem and @typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        var p = typeParts(r, Value, mode, false, where, stack);
        if (attrs.@"comptime") p.keywords = [_]json.Member{.{ .key = "const", .value = example.value(F, attrs.defaultValue(F).?, wayOf(mode), where) }} ++ p.keywords;
        const doc = fieldDocOf(T, name);
        if (doc.description) |text| p.description = &.{text};
        p = withRules(p, rulesOf(T, name));
        p.deprecated = doc.deprecated;
        if (mode == .input and !declarations.writesItself(F)) {
            if (attrs.defaultValue(F)) |default| p.default = example.value(F, default, .input, where);
        }
        const examples = fieldExamples(T, name, wayOf(mode));
        p.examples = (if (examples.example) |one| &[_]json.Node{one} else &[_]json.Node{}) ++ examples.examples;
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
            return .{ .kind = &.{.{ .key = "anyOf", .value = .{ .array = ways } }}, .description = typeTexts(T), .deprecated = typeDeprecated(T), .examples = typeExamples(T, wayOf(mode)) };
        }
        if (nullable) names = names ++ [_]json.Node{.null};
        return .{
            .kind = typeKind("string", nullable),
            .description = typeTexts(T),
            .deprecated = typeDeprecated(T),
            .keywords = &.{.{ .key = "enum", .value = .{ .array = names } }},
            .examples = typeExamples(T, wayOf(mode)),
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
        return .{
            .kind = &.{.{ .key = "oneOf", .value = .{ .array = variants } }},
            .description = typeTexts(T),
            .deprecated = typeDeprecated(T),
            .examples = typeExamples(T, wayOf(mode)),
        };
    }
};

/// Where a parameter is.
pub const Source = enum { path, query, headers, cookies };

/// The parameter of the field `field` of the DTO `Dto`, read from `source`,
/// but its `name`, `in` and `required`: its `description` (the
/// application's text, then what its transforms and rules say), its
/// `deprecated` and `example` from the `FieldDoc` of the field, and its
/// `schema`, with the rules of the field, its default and its `.examples`.
/// A parameter is never null: a `?T` field is one that may be left out. A
/// list in the headers is an item a line, and in the cookies the first
/// cookie of its name, an item alone, as the server reads them.
pub fn parameter(comptime Dto: type, comptime field: []const u8, comptime source: Source) json.Node {
    comptime {
        @setEvalBranchQuota(quota);
        const F = @FieldType(Dto, field);
        const where = typeName(Dto) ++ "." ++ field;
        const Value = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        const Item = listItem(Value) orelse Value;
        if (!isScalar(Item)) @compileError("zefir.openapi: " ++ where ++ ": " ++ @typeName(F) ++ " is not a parameter: a parameter is an integer, a float, bool, an enum or []const u8, alone, as ?T or as []const T");
        var p = Registry.typeParts(null, Value, .input, false, where, &.{});
        // The server keeps the first cookie of a name: a bound of the type,
        // which a rule's bound may only make tighter.
        const cookie_list = source == .cookies and Item != Value;
        if (cookie_list) p.keywords = p.keywords ++ [_]json.Member{count("maxItems", 1)};
        p = withRules(p, rulesAs(Dto, field, Value));
        const attrs = fieldAttrs(Dto, field);
        if (attrs.defaultValue(F)) |default| {
            if (@typeInfo(F) != .optional or default != null) p.default = example.value(F, default, .input, where);
        }
        const examples = fieldExamples(Dto, field, .input);
        p.examples = examples.examples;
        const doc = fieldDocOf(Dto, field);
        var description: []const []const u8 = if (doc.description) |text| &.{text} else &.{};
        description = description ++ p.description;
        if (source == .headers and Item != Value) description = description ++ [_][]const u8{"The server reads an item from each line of this header and does not split a line at commas."};
        if (cookie_list) description = description ++ [_][]const u8{"The server reads only the first cookie of this name: a list of one item."};
        p.description = &.{};
        var members: []const json.Member = &.{};
        if (description.len > 0) members = members ++ [_]json.Member{.{ .key = "description", .value = .{ .string = joined(description) } }};
        if (doc.deprecated) members = members ++ [_]json.Member{.{ .key = "deprecated", .value = .{ .boolean = true } }};
        if (examples.example) |one| members = members ++ [_]json.Member{.{ .key = "example", .value = one }};
        return .{ .object = members ++ [_]json.Member{.{ .key = "schema", .value = node(p) }} };
    }
}

/// A value one string gives: an integer, a float, bool, an enum or
/// `[]const u8`.
fn isScalar(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .int, .float, .bool, .@"enum" => true,
        else => X == []const u8,
    };
}

/// The item of `[]const Item`, else null.
pub fn listItem(comptime X: type) ?type {
    const info = @typeInfo(X);
    if (info != .pointer or info.pointer.size != .slice or X == []const u8) return null;
    return if (X == []const info.pointer.child) info.pointer.child else null;
}

fn fieldAttrs(comptime T: type, comptime name: []const u8) std.lang.Type.Struct.FieldAttributes {
    const s = @typeInfo(T).@"struct";
    for (s.field_names, s.field_attrs) |n, attrs| {
        if (std.mem.eql(u8, n, name)) return attrs;
    }
    unreachable;
}

// ------------------------------------------------------------------ rules

/// The type of `v.rename(...)`, a name, which `v.nameOf` gives: of a
/// constant, so that `rename` runs at compile time.
const rename_example = v.rename("x");
const Rename = @TypeOf(rename_example);
/// The type of a transform: `v.trim`, `v.transformWith(f)`.
const Transform = @TypeOf(v.trim);

/// The schemas of the transforms and rules of the field `name` of `T`, in
/// the order of its entry in `field_rules`, as `v.schemaOf` gives them.
fn rulesOf(comptime T: type, comptime name: []const u8) []const v.RuleSchema {
    return rulesAs(T, name, @FieldType(T, name));
}

/// The schemas of the rules of the field `name` of `T` for values of `F`:
/// a parameter is never null, so the rules of a `?U` one are those of `U`,
/// without `null` in their `enum`.
fn rulesAs(comptime T: type, comptime name: []const u8, comptime F: type) []const v.RuleSchema {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "field_rules")) return &.{};
    if (!@hasField(@TypeOf(T.field_rules), name)) return &.{};
    const entry = @field(T.field_rules, name);
    const E = @TypeOf(entry);
    if (E == v.Rule or E == Transform) return &.{v.schemaOf(entry, F)};
    if (E == Rename) return &.{};
    var out: []const v.RuleSchema = &.{};
    for (0..entry.len) |i| {
        const Element = @TypeOf(entry[i]);
        if (Element == v.Rule or Element == Transform) out = out ++ [_]v.RuleSchema{v.schemaOf(entry[i], F)};
    }
    return out;
}

/// `p` with the schemas of rules and transforms, `schemas`: their keywords
/// merged into those of `p`, their notes after its description, and the
/// schemas of `each` applied to its items the same way.
fn withRules(comptime p: Parts, comptime schemas: []const v.RuleSchema) Parts {
    var out = p;
    var fragments: []const []const json.Member = &.{};
    var notes: []const []const u8 = &.{};
    for (schemas) |rs| {
        if (rs.note) |note| notes = notes ++ [_][]const u8{note};
        if (rs.keywords.len > 0) {
            var members: [rs.keywords.len]json.Member = undefined;
            for (rs.keywords, &members) |k, *m| m.* = .{ .key = k.name, .value = .{ .raw = k.value } };
            const final = members;
            fragments = fragments ++ [_][]const json.Member{&final};
        }
        if (rs.items.len > 0) {
            const items = withRules(out.items.?.*, rs.items);
            out.items = &items;
        }
    }
    out.keywords = merged(out, fragments);
    out.description = out.description ++ notes;
    return out;
}

/// The keywords of `p` and those of the rules, `fragments`, one each. A
/// keyword of the type and the same of a rule keep the tighter bound, or
/// the rule's `enum`, a part of the type's. Two rules with one keyword, or
/// a rule with a keyword that the schema has for another reason, cannot be
/// one object: then the type's keywords stay, and each rule's go into
/// `allOf`.
fn merged(comptime p: Parts, comptime fragments: []const []const json.Member) []const json.Member {
    if (fragments.len == 0) return p.keywords;
    const taken = takenKeys(p);
    var keywords = p.keywords;
    var names: []const []const u8 = &.{};
    for (fragments) |fragment| {
        for (fragment) |k| {
            if (contains(names, k.key) or contains(taken, k.key)) return withAllOf(p.keywords, fragments);
            names = names ++ [_][]const u8{k.key};
            for (keywords, 0..) |own, i| {
                if (!std.mem.eql(u8, own.key, k.key)) continue;
                const kept = tighter(own, k) orelse return withAllOf(p.keywords, fragments);
                keywords = keywords[0..i] ++ [_]json.Member{kept} ++ keywords[i + 1 ..];
                break;
            } else keywords = keywords ++ [_]json.Member{k};
        }
    }
    return keywords;
}

fn withAllOf(comptime keywords: []const json.Member, comptime fragments: []const []const json.Member) []const json.Member {
    var all: []const json.Node = &.{};
    for (fragments) |fragment| all = all ++ [_]json.Node{.{ .object = fragment }};
    return keywords ++ [_]json.Member{.{ .key = "allOf", .value = .{ .array = all } }};
}

/// The keys of `p` besides its keywords.
fn takenKeys(comptime p: Parts) []const []const u8 {
    var out: []const []const u8 = &.{ "description", "deprecated", "default", "examples" };
    for (p.kind) |m| out = out ++ [_][]const u8{m.key};
    if (p.items != null) out = out ++ [_][]const u8{"items"};
    if (p.properties != null) out = out ++ [_][]const u8{ "required", "properties", "additionalProperties" };
    return out;
}

/// Of a keyword of the type, `own`, and the same keyword of a rule, the one
/// to keep: the tighter bound, or the rule's `enum`; null for a keyword
/// that is neither.
fn tighter(comptime own: json.Member, comptime rule: json.Member) ?json.Member {
    const key = own.key;
    if (std.mem.eql(u8, key, "enum")) return rule;
    if (own.value != .raw or rule.value != .raw) return null;
    const lower = contains(&.{ "minimum", "exclusiveMinimum", "minLength", "minItems" }, key);
    const upper = contains(&.{ "maximum", "exclusiveMaximum", "maxLength", "maxItems" }, key);
    if (!lower and !upper) return null;
    const rule_less = lessNumber(rule.value.raw, own.value.raw) orelse return null;
    // The greater of two lower bounds, the less of two upper ones.
    return if (rule_less == upper) rule else own;
}

/// Whether the JSON number `a` is less than `b`; null when one is not a
/// number.
fn lessNumber(comptime a: []const u8, comptime b: []const u8) ?bool {
    if (integerOf(a)) |x| if (integerOf(b)) |y| return x < y;
    const x = std.fmt.parseFloat(f128, a) catch return null;
    const y = std.fmt.parseFloat(f128, b) catch return null;
    return x < y;
}

/// The integer of the JSON text `text`, or null when it is not one.
fn integerOf(comptime text: []const u8) ?comptime_int {
    const negative = text.len > 0 and text[0] == '-';
    const digits = if (negative) text[1..] else text;
    if (digits.len == 0) return null;
    var n: comptime_int = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + @as(comptime_int, c - '0');
    }
    return if (negative) -n else n;
}

fn contains(comptime list: []const []const u8, comptime key: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

// ------------------------------------------------------------------ examples

/// The `examples` of the schema of `T`: its `Doc(T).example`, as it goes
/// `way`. Every example of a struct, those of `.examples` too, passes the
/// rules of the struct, or the build stops.
fn typeExamples(comptime T: type, comptime way: example.Way) []const json.Node {
    const doc = docOf(T) orelse return &.{};
    if (!@hasField(@TypeOf(doc), "example")) return &.{};
    if (@typeInfo(T) == .@"struct") {
        if (doc.example) |x| {
            if (exampleProblem(T, x, typeName(T) ++ ".openapi.example")) |text| @compileError(text);
        }
        for (doc.examples, 0..) |e, i| {
            if (exampleProblem(T, e.value, std.fmt.comptimePrint("{s}.openapi.examples[{d}]", .{ typeName(T), i }))) |text| @compileError(text);
        }
    }
    const x = doc.example orelse return &.{};
    return &.{example.value(T, x, way, typeName(T) ++ ".openapi.example")};
}

/// The examples of a field: its `.example` and its `.examples`.
const FieldExamples = struct { example: ?json.Node = null, examples: []const json.Node = &.{} };

/// The examples of the field `name` of `T`, as they go `way`; each passes
/// the rules of the field, or the build stops.
fn fieldExamples(comptime T: type, comptime name: []const u8, comptime way: example.Way) FieldExamples {
    const F = @FieldType(T, name);
    const doc = fieldDocOf(T, name);
    if (!@hasField(@TypeOf(doc), "example")) return .{};
    const where = typeName(T) ++ ".openapi.fields." ++ name;
    var out: FieldExamples = .{};
    if (doc.example) |x| {
        if (fieldExampleProblem(T, name, x, where ++ ".example")) |text| @compileError(text);
        out.example = example.value(F, x, way, where ++ ".example");
    }
    for (doc.examples, 0..) |x, i| {
        const at = std.fmt.comptimePrint("{s}.examples[{d}]", .{ where, i });
        if (fieldExampleProblem(T, name, x, at)) |text| @compileError(text);
        out.examples = out.examples ++ [_]json.Node{example.value(F, x, way, at)};
    }
    return out;
}

/// The error of the example `x` of the struct `T`, named `where`, that
/// breaks a rule of `T`; null when it passes them all, as `v.check` finds.
pub fn exampleProblem(comptime T: type, comptime x: T, comptime where: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const violation = v.check(&x, &buf) orelse return null;
    const field = violation.field orelse "";
    const at = if (field.len > 0) field ++ " " else "";
    return "zefir.openapi: " ++ where ++ ": " ++ at ++ violation.message ++ " (" ++ violation.code ++ "); give an example that passes the rules of " ++ typeName(T);
}

/// The error of `x`, an example of the field `name` of `T`, that breaks a
/// rule of the field or of a type inside it; null when it passes them all.
pub fn fieldExampleProblem(comptime T: type, comptime name: []const u8, comptime x: @FieldType(T, name), comptime where: []const u8) ?[]const u8 {
    const F = @FieldType(T, name);
    const ruled = @typeInfo(T) == .@"struct" and @hasDecl(T, "field_rules") and @hasField(@TypeOf(T.field_rules), name);
    const Box = if (ruled) Ruled(F, @field(T.field_rules, name)) else Plain(F);
    var buf: [256]u8 = undefined;
    const box: Box = .{ .value = x };
    const violation = v.check(&box, &buf) orelse return null;
    // The box's field stands for the field: its outside name.
    const path = violation.field orelse "";
    const outside = if (@typeInfo(T) == .@"struct") v.nameOf(T, @field(std.meta.FieldEnum(T), name)) else name;
    const at = outside ++ path[std.mem.findAny(u8, path, ".[") orelse path.len ..];
    return "zefir.openapi: " ++ where ++ ": " ++ at ++ " " ++ violation.message ++ " (" ++ violation.code ++ "); give an example that passes the rules of " ++ typeName(T) ++ "." ++ name;
}

/// A value of `F` with the rules `entry` of a field.
fn Ruled(comptime F: type, comptime entry: anytype) type {
    return struct {
        value: F,
        pub const field_rules = .{ .value = entry };
    };
}

/// A value of `F`, with the rules of the types inside it.
fn Plain(comptime F: type) type {
    return struct { value: F };
}

/// What the description of a struct with `validateSelf`, which checks
/// fields against each other, adds: the schema cannot say it.
fn selfNote(comptime T: type) []const []const u8 {
    if (@hasDecl(T, "validateSelf")) return &.{"The server also checks how these fields fit together."};
    return &.{};
}

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
pub fn docOf(comptime T: type) ?declarations.Doc(T) {
    if (!@hasDecl(T, "openapi")) return null;
    if (@TypeOf(T.openapi) != declarations.Doc(T))
        @compileError("zefir.openapi: " ++ typeName(T) ++ ".openapi must be of type zefir.openapi.Doc(" ++ typeName(T) ++ ")");
    return T.openapi;
}

/// The texts of the field `name` of `T`, `.{}` when it has none.
fn fieldDocOf(comptime T: type, comptime name: []const u8) declarations.FieldDoc(@FieldType(T, name)) {
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
/// stands inline, and so does a generic of one.
fn isNamed(comptime T: type) bool {
    if (docOf(T)) |doc| if (doc.name != null) return true;
    return !isAnonymous(T);
}

/// The compiler names an anonymous type after its place and a number,
/// `dto.Order__struct_931`, and a generic of one by it too,
/// `dto.Page(dto.list__struct_935)`: the name `schemaName` would give
/// either holds that number.
fn isAnonymous(comptime T: type) bool {
    return hasCompilerNumber(schemaName(@typeName(T)));
}

/// Whether `name` holds the number of an anonymous type anywhere:
/// `__struct_`, `__union_`, `__enum_` or `__opaque_`, then a digit.
fn hasCompilerNumber(comptime name: []const u8) bool {
    var rest = name;
    while (std.mem.find(u8, rest, "__")) |at| {
        rest = rest[at + 2 ..];
        for ([_][]const u8{ "struct_", "union_", "enum_", "opaque_" }) |kind| {
            if (std.mem.startsWith(u8, rest, kind) and rest.len > kind.len and std.ascii.isDigit(rest[kind.len])) return true;
        }
    }
    return false;
}

/// The name of the schema of `T`: its `Doc(T).name`, else the one of
/// `schemaName`; a name that is not one stops the build.
fn checkedName(comptime T: type) []const u8 {
    const rule = "1 or more of A-Z, a-z, 0-9, '.', '-' and '_'";
    if (docOf(T)) |doc| if (doc.name) |name| {
        if (!isSchemaName(name)) @compileError("zefir.openapi: " ++ typeName(T) ++ ".openapi.name \"" ++ name ++ "\" is not a schema name: " ++ rule);
        return name;
    };
    const name = schemaName(@typeName(T));
    if (!isSchemaName(name)) @compileError("zefir.openapi: the schema of " ++ @typeName(T) ++ " would be named " ++ name ++ ", which is not a schema name (" ++ rule ++
        "); give it one: pub const openapi: zefir.openapi.Doc(@This()) = .{ .name = \"...\" }");
    return name;
}

/// A name the document can give a schema: `^[a-zA-Z0-9.\-_]+$`.
fn isSchemaName(comptime name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    }
    return true;
}

/// The name of a schema from the name of its type, `@typeName`: its last
/// part, a generic's arguments after it, each by its own last part:
/// "dto.TodoResponse" is "TodoResponse", "dto.Page(dto.TodoResponse)" is
/// "Page_TodoResponse", "dto.Pair(dto.Todo,u8)" is "Pair_Todo_u8", and an
/// argument "[]const dto.Todo" or "?dto.Todo" is "Todo".
fn schemaName(comptime full: []const u8) []const u8 {
    const name = bare(lastWord(full));
    const open = std.mem.findScalar(u8, name, '(') orelse return name;
    if (name[name.len - 1] != ')') return name;
    var out: []const u8 = name[0..open];
    var depth: usize = 0;
    var start = open + 1;
    for (name[open + 1 .. name.len - 1], open + 1..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        ',' => if (depth == 0) {
            out = out ++ "_" ++ schemaName(name[start..i]);
            start = i + 1;
        },
        else => {},
    };
    if (start < name.len - 1) out = out ++ "_" ++ schemaName(name[start .. name.len - 1]);
    return out;
}

/// The last word of a type's name outside parentheses, after its last '.'
/// or ' ': "[]const dto.Todo" is "Todo", "dto.Page(dto.Todo)" is
/// "Page(dto.Todo)".
fn lastWord(comptime full: []const u8) []const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.', ' ' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return full[start..];
}

/// A name without the `?`, `*` and `[N]` in front of it.
fn bare(comptime name: []const u8) []const u8 {
    var rest = name;
    while (rest.len > 0) {
        switch (rest[0]) {
            '?', '*' => rest = rest[1..],
            '[' => rest = rest[(std.mem.findScalar(u8, rest, ']') orelse return rest) + 1 ..],
            else => return rest,
        }
    }
    return rest;
}

fn lessName(comptime a: Registry.Schema, comptime b: Registry.Schema) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
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

const testing = std.testing;

test "schemaName: the last part of a type's name, a generic's arguments each by its own" {
    // The names `@typeName` gives, as Zig 0.17 prints them.
    try testing.expectEqualStrings("TodoResponse", comptime schemaName("dto.TodoResponse"));
    try testing.expectEqualStrings("Inner", comptime schemaName("dto.Outer.Inner"));
    try testing.expectEqualStrings("Page_TodoResponse", comptime schemaName("dto.Page(dto.TodoResponse)"));
    try testing.expectEqualStrings("Pair_Todo_u8", comptime schemaName("dto.Pair(dto.Todo,u8)"));
    try testing.expectEqualStrings("Page_Page_Todo", comptime schemaName("dto.Page(dto.Page(dto.Todo))"));
    try testing.expectEqualStrings("Page_u8", comptime schemaName("dto.Page([]const u8)"));
    try testing.expectEqualStrings("Page_Todo", comptime schemaName("dto.Page(?dto.Todo)"));
    try testing.expectEqualStrings("Page_Todo", comptime schemaName("dto.Page([]const dto.Todo)"));
    try testing.expectEqualStrings("Grid_u8", comptime schemaName("dto.Grid([3]u8)"));
    try testing.expectEqualStrings("Limited_5", comptime schemaName("dto.Limited(5)"));
    try testing.expectEqualStrings("Todo", comptime schemaName("dto.test.a test of mine.Todo"));
    // A string argument gives no name; the build asks for a .name then.
    try testing.expect(!comptime isSchemaName(schemaName("dto.Named(\"abc\"[0..3])")));
}

test "isSchemaName: ^[a-zA-Z0-9.\\-_]+$" {
    try testing.expect(comptime isSchemaName("Page_Todo-Input.v2"));
    try testing.expect(!comptime isSchemaName(""));
    try testing.expect(!comptime isSchemaName("Page Todo"));
    try testing.expect(!comptime isSchemaName("Todo$"));
}

test "isAnonymous: the compiler's name of an anonymous type" {
    try testing.expect(comptime isAnonymous(struct { a: u8 }));
    try testing.expect(comptime isAnonymous(enum { a }));
    try testing.expect(comptime !isAnonymous(http.Problem));
    // A generic of one holds its number among its arguments.
    try testing.expect(comptime isAnonymous(TestPair(struct { a: u8 }, u8)));
    try testing.expect(comptime !isAnonymous(TestPair(http.Problem, u8)));
}

fn TestPair(comptime A: type, comptime B: type) type {
    return struct { a: A, b: B };
}

test {
    _ = @import("tests/schema_test.zig");
}
