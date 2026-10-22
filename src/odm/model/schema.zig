//! The schema of a model and the types that odm makes from the fields of
//! one. A model is a plain struct that declares its schema in itself:
//!
//! ```zig
//! pub const User = struct {
//!     id: ?bson.ObjectId = null, // null: odm makes an ObjectId on insert
//!     email: []const u8,
//!     profile: ?Profile = null,
//!     created_at: bson.DateTime,
//!
//!     pub const Profile = struct { city: []const u8, country: []const u8 };
//!
//!     pub const odm_schema: odm.Schema(User) = .{
//!         .collection = "users",
//!         .id = .id, // in the database this field is _id
//!         .names = .{ .created_at = "createdAt" },
//!         .indexes = &.{
//!             .{ .keys = &.{.{ .email = .asc }}, .unique = true },
//!             .{ .keys = &.{ .{ .@"profile.city" = .asc }, .{ .created_at = .desc } } },
//!         },
//!     };
//! };
//! ```
//!
//! The types of the schema stand on the fields of the model alone, never
//! on its declarations, so that a model can name its own schema type.

const std = @import("std");
const bson = @import("mongo-bson");
const v = @import("validator");

/// The comptime branch quota of the walks over a model: a model with many
/// fields and paths never stops a build with "evaluation exceeded".
pub const eval_quota = 10_000_000;

/// The schema of the model `T`, which `T` declares as
/// `pub const odm_schema: odm.Schema(T) = .{ … }`.
pub fn Schema(comptime T: type) type {
    requireStruct(T);
    return struct {
        /// The collection of the model: 1–191 bytes of UTF-8, without '$'
        /// and NUL, not "system.…".
        collection: []const u8,
        /// The field that is the id of the model: in the database it is
        /// always `_id`, which odm writes itself.
        id: std.meta.FieldEnum(T),
        /// The BSON keys of the top-level fields whose keys are not their
        /// Zig names: `.{ .created_at = "createdAt" }`. The fields of
        /// structs inside keep their Zig names.
        names: Names(T) = .{},
        /// The indexes that `ensureIndexes` creates.
        indexes: []const Index(T) = &.{},
    };
}

/// A struct with a field `?[]const u8 = null` for each field of `T`.
pub fn Names(comptime T: type) type {
    requireStruct(T);
    const fields = @typeInfo(T).@"struct".field_names;
    const none: ?[]const u8 = null;
    return @Struct(.auto, null, fields, &@splat(?[]const u8), &@splat(.{ .default_value_ptr = &none }));
}

/// An index of the collection of the model `T`.
pub fn Index(comptime T: type) type {
    return struct {
        /// The keys of the index in their order, one in each item:
        /// `&.{ .{ .status = .asc }, .{ .created_at = .desc } }`.
        keys: []const IndexKey(T),
        /// When every key is optional, only with `sparse`: odm leaves a
        /// null optional out, and the documents without the field would
        /// collide in the index.
        unique: bool = false,
        sparse: bool = false,
        /// A TTL index: one key, on a `bson.DateTime` field.
        expire_after_seconds: ?u32 = null,
        /// Null: the name that MongoDB makes from the BSON keys, such as
        /// "status_1_createdAt_-1".
        name: ?[]const u8 = null,
    };
}

/// A key of an index: one path of the model `T` with its order,
/// `.{ .email = .asc }`, `.{ .@"profile.city" = .desc }`. A union tagged by
/// `Path(T)`.
pub fn IndexKey(comptime T: type) type {
    const P = Path(T);
    const names = @typeInfo(P).@"enum".field_names;
    return @Union(.auto, P, names, &@splat(IndexOrder), &@splat(.{}));
}

/// The order of a key of an index.
pub const IndexOrder = enum { asc, desc, text, hashed };

/// An enum of every path of the fields of `T`: the Zig names of the fields
/// on the way, joined by '.', depth-first in the order of declaration. A
/// path goes on through an optional and through a list of structs
/// (`[]const S`, `[N]S`): "profile.city", "items.sku". The special types
/// of BSON, `bson.RawDocument` and `bson.Value` end a path.
pub fn Path(comptime T: type) type {
    const all = paths(T);
    var names: [all.len][]const u8 = undefined;
    for (all, &names) |entry, *name| name.* = entry.name;
    const Tag = std.math.IntFittingRange(0, all.len - 1);
    return @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, all.len));
}

/// A path of the fields of a model, as `Path` lists it.
pub const PathEntry = struct {
    /// The Zig names of the fields on the way, joined by '.'.
    name: []const u8,
    /// The type of the field at the end of the path, as it is declared.
    Type: type,
    /// Whether the field at the end, or a field on the way, is optional, so
    /// that a document may lack the path. The id of a model counts here by
    /// its type; odm always writes it.
    optional: bool,
};

/// The paths of the fields of `T`, in the order of `Path(T)`.
pub fn paths(comptime T: type) []const PathEntry {
    comptime {
        @setEvalBranchQuota(eval_quota);
        requireStruct(T);
        return walkPaths(T, "", false, &.{T});
    }
}

/// The paths of the fields of the struct `S`, under `prefix`. `outer`
/// holds the structs on the way, so that a type that holds itself ends a
/// path instead of an endless descent; the check of the model reports it.
/// A name with a dot stops the build here: the schema of the model makes
/// its paths before any other check of the model runs.
fn walkPaths(comptime S: type, comptime prefix: []const u8, comptime optional: bool, comptime outer: []const type) []const PathEntry {
    var out: []const PathEntry = &.{};
    const info = @typeInfo(S).@"struct";
    for (info.field_names, info.field_types) |name, F| {
        requireNoDot(@typeName(outer[0]), prefix, name);
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        const maybe = optional or @typeInfo(F) == .optional;
        out = out ++ &[_]PathEntry{.{ .name = path, .Type = F, .optional = maybe }};
        if (Inner(F)) |Sub| {
            if (!holds(outer, Sub)) out = out ++ walkPaths(Sub, path, maybe, outer ++ &[_]type{Sub});
        }
    }
    return out;
}

fn holds(comptime types: []const type, comptime T: type) bool {
    for (types) |Other| {
        if (Other == T) return true;
    }
    return false;
}

/// Stops the build at the field `name` of the struct at `prefix` of the
/// model `M` when the name holds a dot: odm reads a dot as a step of a
/// path, in filters, updates, sorts and indexes.
fn requireNoDot(comptime M: []const u8, comptime prefix: []const u8, comptime name: []const u8) void {
    if (std.mem.findScalar(u8, name, '.') == null) return;
    const at = if (prefix.len == 0) M else M ++ "." ++ prefix;
    @compileError("odm: " ++ at ++ ": the field '" ++ name ++ "' holds '.', which odm reads as a step of a path; rename the field");
}

/// The struct whose fields the paths of a field of type `F` go on into:
/// `F` itself, the child of an optional, or the item of a list; null for a
/// field that ends its paths.
fn Inner(comptime F: type) ?type {
    const T = Unwrap(F);
    if (isDocument(T)) return T;
    const Item = ListItem(T) orelse return null;
    const Plain = Unwrap(Item);
    return if (isDocument(Plain)) Plain else null;
}

/// `T` without its optional.
pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

/// The item of the list type `T` (`[]const E`, `[N]E`), or null. A string
/// is not a list.
pub fn ListItem(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| if (info.size == .slice and info.child != u8) info.child else null,
        else => null,
    };
}

/// Whether the codec writes `T` as a document of its fields: a struct with
/// named fields that is not one of the types of BSON.
pub fn isDocument(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and !bson.codec.check.isSpecial(T),
        else => false,
    };
}

/// Stops the build when `T` cannot be a model at all.
fn requireStruct(comptime T: type) void {
    if (!isModelShape(T)) @compileError("odm: " ++ @typeName(T) ++ " is not a model: a model is a struct with named fields");
}

fn isModelShape(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and info.field_names.len > 0,
        else => false,
    };
}

/// What an insert of the model `T` takes: `T` itself, or, when the id of
/// `T` is a `bson.ObjectId` (not optional), `T` without the id, which odm
/// always makes. The other fields keep their types and default values.
pub fn Insert(comptime T: type) type {
    check(T);
    if (idKind(T) != .object_id) return T;
    const info = @typeInfo(T).@"struct";
    const id = idName(T);
    const n = info.field_names.len - 1;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    var i: usize = 0;
    for (info.field_names, info.field_types, info.field_attrs) |name, F, field_attrs| {
        if (std.mem.eql(u8, name, id)) continue;
        names[i] = name;
        types[i] = F;
        attrs[i] = field_attrs;
        i += 1;
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The type of the id of the model `T`, without the optional:
/// `bson.ObjectId` for `?bson.ObjectId`.
pub fn Id(comptime T: type) type {
    check(T);
    return Unwrap(@FieldType(T, idName(T)));
}

/// How the id of a model is made.
pub const IdKind = enum {
    /// `?bson.ObjectId`: null on insert makes odm make one; a value is
    /// written as it is.
    optional_object_id,
    /// `bson.ObjectId`: odm always makes it, and `Insert(T)` has no id.
    object_id,
    /// Any other type: the application gives the id on insert.
    given,
};

/// The name of the field that is the id of the model `T`.
pub fn idName(comptime T: type) []const u8 {
    return @tagName(T.odm_schema.id);
}

/// How the id of the model `T` is made.
pub fn idKind(comptime T: type) IdKind {
    const F = @FieldType(T, idName(T));
    if (F == ?bson.ObjectId) return .optional_object_id;
    if (F == bson.ObjectId) return .object_id;
    return .given;
}

/// The BSON key of the top-level field `field` of the model `T`: `_id` for
/// the id, else its name in `odm_schema.names`, else its Zig name.
pub fn keyOf(comptime T: type, comptime field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, idName(T))) return "_id";
    if (@hasField(Names(T), field)) {
        if (@field(T.odm_schema.names, field)) |key| return key;
    }
    return field;
}

/// Every check of a model, at compile time: its shape, its schema (the
/// collection, the id, the BSON names, the indexes), the types of its
/// fields, then the declarations of zefir-validator in it and below it.
/// A problem stops the build with a message that starts with "odm: " and
/// names the model by `@typeName`; those of the validator start with
/// "validator: ". `odm.assertModel`, `Insert`, `Id` and the typed
/// operations call it.
pub fn check(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(eval_quota);
        const M = @typeName(T);
        requireStruct(T);
        if (!@hasDecl(T, "odm_schema")) @compileError("odm: " ++ M ++ " has no pub const odm_schema; declare pub const odm_schema: odm.Schema(" ++ M ++ ") = .{ .collection = \"...\", .id = .id };");
        if (@TypeOf(T.odm_schema) != Schema(T)) @compileError("odm: " ++ M ++ ".odm_schema must be an odm.Schema(" ++ M ++ "); got " ++ @typeName(@TypeOf(T.odm_schema)));
        checkCollection(M, T.odm_schema.collection);
        checkId(T, M);
        checkNames(T, M);
        // A model is both read and written.
        if (bson.codec.check.document(T, .decode)) |problem| @compileError("odm: " ++ M ++ ": " ++ problem);
        if (bson.codec.check.document(T, .encode)) |problem| @compileError("odm: " ++ M ++ ": " ++ problem);
        checkKeys(T, M);
        if (fieldOf(T, "", isF32)) |path| @compileError("odm: " ++ M ++ "." ++ path ++ " is f32: a BSON double has 64 bits, and decoding one into f32 rounds it; use f64");
        if (fieldOf(T, "", hasOptionalDefault)) |path| @compileError("odm: " ++ M ++ "." ++ path ++ " is optional, and its default is not null: odm leaves a null optional out of the document, and a field that is not there reads back as its default; make the default null");
        checkIndexes(T, M);
        v.assertRules(T);
    }
}

fn checkCollection(comptime M: []const u8, comptime name: []const u8) void {
    const at = "odm: " ++ M ++ ".odm_schema.collection";
    if (name.len == 0) @compileError(at ++ " is empty");
    if (std.mem.findAny(u8, name, "$\x00") != null) @compileError(at ++ " holds '$' or NUL");
    if (std.mem.startsWith(u8, name, "system.")) @compileError(at ++ " starts with \"system.\"");
    if (name.len > 191) @compileError(at ++ " is longer than 191 bytes");
    if (!std.unicode.utf8ValidateSlice(name)) @compileError(at ++ " is not UTF-8");
}

fn checkId(comptime T: type, comptime M: []const u8) void {
    const id = idName(T);
    const F = @FieldType(T, id);
    if (@typeInfo(F) == .optional and F != ?bson.ObjectId) {
        @compileError("odm: " ++ M ++ "." ++ id ++ " is the id of the model and is " ++ @typeName(F) ++
            ": an id is bson.ObjectId, ?bson.ObjectId, or a value of another type that you give on insert and that is not optional");
    }
    // The server refuses them on the first insert.
    if (ListItem(F) != null or F == bson.Regex) {
        @compileError("odm: " ++ M ++ "." ++ id ++ " is the id of the model and is " ++ @typeName(F) ++
            ": MongoDB takes no array or regular expression as _id; for bytes, such as a UUID, use bson.Binary");
    }
    if (@hasField(T, "_id") and !std.mem.eql(u8, id, "_id")) {
        @compileError("odm: " ++ M ++ "._id is not the id of the model: set odm_schema.id = ._id, or rename the field");
    }
}

/// The names of `odm_schema.names`, the BSON names of all fields, and the
/// Zig names that a filter takes for its logical operators.
fn checkNames(comptime T: type, comptime M: []const u8) void {
    const fields = @typeInfo(T).@"struct".field_names;
    const id = idName(T);
    for (fields) |field| {
        const key = @field(T.odm_schema.names, field) orelse continue;
        const at = "odm: " ++ M ++ ".odm_schema.names." ++ field;
        if (std.mem.eql(u8, field, id)) @compileError(at ++ ": the id of the model is always _id in the database; drop this name");
        if (key.len == 0 or key[0] == '$' or std.mem.findAny(u8, key, ".\x00") != null) {
            @compileError(at ++ ": \"" ++ key ++ "\" is not a field name of a document: it is empty, starts with '$', or holds '.' or NUL");
        }
        if (!std.unicode.utf8ValidateSlice(key)) @compileError(at ++ ": the name is not UTF-8");
    }
    for (fields, 0..) |a, i| {
        const key = keyOf(T, a);
        for (fields[i + 1 ..]) |b| {
            if (std.mem.eql(u8, key, keyOf(T, b))) @compileError("odm: " ++ M ++ ": the fields '" ++ a ++ "' and '" ++ b ++ "' both have the BSON name \"" ++ key ++ "\"");
        }
    }
    for (fields) |field| {
        for ([_][]const u8{ "and", "or", "nor" }) |operator| {
            if (std.mem.eql(u8, field, operator)) {
                @compileError("odm: " ++ M ++ "." ++ field ++ ": and, or and nor are the logical operators of filters; rename the field and keep its BSON name with odm_schema.names");
            }
        }
    }
}

/// The names of the fields of `T` and of the structs in it, through
/// optionals and lists, as a document holds them: the BSON name of a
/// top-level field (`checkNames` checks those of `odm_schema.names`), the
/// Zig name of one below; no Zig name holds a dot. The codec check has
/// refused the types that hold themselves.
fn checkKeys(comptime T: type, comptime M: []const u8) void {
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, F| {
        requireNoDot(M, "", name);
        // The id is _id in the database.
        const renamed = @field(T.odm_schema.names, name) != null or std.mem.eql(u8, name, idName(T));
        if (!renamed) checkKey(M, name, name, true);
        checkKeysIn(F, M, name);
    }
}

fn checkKeysIn(comptime F: type, comptime M: []const u8, comptime path: []const u8) void {
    const S = Unwrap(F);
    if (isDocument(S)) {
        const info = @typeInfo(S).@"struct";
        for (info.field_names, info.field_types) |name, Field| {
            requireNoDot(M, path, name);
            checkKey(M, path ++ "." ++ name, name, false);
            checkKeysIn(Field, M, path ++ "." ++ name);
        }
        return;
    }
    const Item = ListItem(S) orelse return;
    checkKeysIn(Item, M, path ++ "[]");
}

/// Stops the build at the name `key` of the field at `path`, unless a
/// document can hold it: it does not start with '$' and is UTF-8. Zig
/// refuses an empty name and a NUL in one already.
fn checkKey(comptime M: []const u8, comptime path: []const u8, comptime key: []const u8, comptime top: bool) void {
    const fix = if (top) "rename the field, or give it a BSON name with odm_schema.names" else "rename the field";
    if (key[0] == '$') @compileError("odm: " ++ M ++ "." ++ path ++ ": the name \"" ++ key ++ "\" starts with '$', which MongoDB reads as an operator; " ++ fix);
    if (!std.unicode.utf8ValidateSlice(key)) {
        // Not the name itself: the message stays UTF-8.
        const parent = path[0 .. path.len - key.len];
        const at = if (parent.len == 0) M else M ++ "." ++ parent[0 .. parent.len - 1];
        @compileError("odm: " ++ at ++ ": a field has a name that is not UTF-8, which a document needs; " ++ fix);
    }
}

/// The path of the first field of the struct `S` and of the structs in it,
/// through optionals and lists, for which `found(Field, attrs)` holds, or
/// null. The path names the fields by their Zig names joined by '.', with
/// `[]` for each list on the way: "items[].qty". The codec check has
/// refused the types that hold themselves.
fn fieldOf(comptime S: type, comptime prefix: []const u8, comptime found: anytype) ?[]const u8 {
    const info = @typeInfo(S).@"struct";
    for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const path = prefix ++ name;
        if (found(F, attrs)) return path;
        if (inType(F, path, found)) |inner| return inner;
    }
    return null;
}

/// `fieldOf` for the structs that a value of type `F` at `path` holds; an
/// f32 that is a list's item is found here too.
fn inType(comptime F: type, comptime path: []const u8, comptime found: anytype) ?[]const u8 {
    const T = Unwrap(F);
    if (isDocument(T)) return fieldOf(T, path ++ ".", found);
    const Item = ListItem(T) orelse return null;
    if (found(Item, .{})) return path ++ "[]";
    return inType(Item, path ++ "[]", found);
}

fn isF32(comptime F: type, comptime _: std.lang.Type.Struct.FieldAttributes) bool {
    return Unwrap(F) == f32;
}

fn hasOptionalDefault(comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes) bool {
    if (@typeInfo(F) != .optional) return false;
    const default = attrs.defaultValue(F) orelse return false;
    return default != null;
}

fn checkIndexes(comptime T: type, comptime M: []const u8) void {
    const indexes = T.odm_schema.indexes;
    for (indexes, 0..) |index, i| {
        const at = std.fmt.comptimePrint("odm: {s}.odm_schema.indexes[{d}]", .{ M, i });
        if (index.keys.len == 0) @compileError(at ++ " has no keys");
        for (index.keys, 0..) |key, j| {
            for (index.keys[0..j]) |earlier| {
                if (@backingInt(earlier) == @backingInt(key)) @compileError(at ++ ": the key '" ++ @tagName(key) ++ "' comes twice");
            }
            const F = entryOf(T, key).Type;
            if (orderOf(key) == .text and !isText(F)) {
                @compileError(at ++ ": a text key needs a string field; " ++ M ++ "." ++ @tagName(key) ++ " is " ++ @typeName(F));
            }
        }
        if (index.expire_after_seconds != null) {
            if (index.keys.len != 1 or Unwrap(entryOf(T, index.keys[0]).Type) != bson.DateTime) {
                @compileError(at ++ ": expire_after_seconds needs one key on a bson.DateTime field");
            }
        }
        for (indexes[0..i], 0..) |earlier, e| {
            if (sameKeys(earlier.keys, index.keys)) @compileError(std.fmt.comptimePrint("odm: {s}.odm_schema.indexes[{d}] and [{d}] have the same keys", .{ M, e, i }));
        }
        if (index.unique and !index.sparse) {
            for (index.keys) |key| {
                // odm always writes the id.
                if (!entryOf(T, key).optional or std.mem.eql(u8, @tagName(key), idName(T))) break;
            } else {
                @compileError(at ++ " is unique on " ++ M ++ "." ++ @tagName(index.keys[0]) ++ ", which is optional: odm leaves null out, and the documents without the field would collide in the index as null; add .sparse = true");
            }
        }
    }
}

/// The path of a key of an index of `T`.
fn entryOf(comptime T: type, comptime key: IndexKey(T)) PathEntry {
    return paths(T)[@backingInt(key)];
}

fn orderOf(comptime key: anytype) IndexOrder {
    return switch (key) {
        inline else => |order| order,
    };
}

fn sameKeys(comptime a: anytype, comptime b: @TypeOf(a)) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (@backingInt(x) != @backingInt(y) or orderOf(x) != orderOf(y)) return false;
    }
    return true;
}

/// Whether a text index takes a field of type `F`: a string, or a list of
/// strings.
fn isText(comptime F: type) bool {
    const T = Unwrap(F);
    if (T == []const u8) return true;
    const Item = ListItem(T) orelse return false;
    return Unwrap(Item) == []const u8;
}
