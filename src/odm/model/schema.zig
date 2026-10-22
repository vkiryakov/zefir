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
fn walkPaths(comptime S: type, comptime prefix: []const u8, comptime optional: bool, comptime outer: []const type) []const PathEntry {
    var out: []const PathEntry = &.{};
    const info = @typeInfo(S).@"struct";
    for (info.field_names, info.field_types) |name, F| {
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
fn isDocument(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and !bson.codec.check.isSpecial(T),
        else => false,
    };
}

/// Stops the build when `T` cannot be a model at all.
fn requireStruct(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| if (!info.is_tuple and info.field_names.len > 0) return,
        else => {},
    }
    @compileError("odm: " ++ @typeName(T) ++ " is not a model: a model is a struct with named fields");
}

/// What an insert of the model `T` takes: `T` itself, or, when the id of
/// `T` is a `bson.ObjectId` (not optional), `T` without the id, which odm
/// always makes. The other fields keep their types and default values.
pub fn Insert(comptime T: type) type {
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
