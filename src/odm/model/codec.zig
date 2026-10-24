//! The documents of a model, which the collections and cursors of odm
//! write and read: the top-level fields under their BSON names from the
//! schema, the id as `_id`, the fields of the structs inside by their Zig
//! names. An optional that is null is never written, at any depth; a null
//! item of a list stays, as it is an item and not a field. A missing
//! optional and a null of another writer read as null.

const std = @import("std");
const bson = @import("mongo-bson");
const errors = @import("../errors.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;
const Diagnostics = errors.Diagnostics;

/// What a document of a model is for.
pub const Mode = enum {
    /// The document of an insert: the id is `_id`.
    insert,
    /// The replacement of a `replaceOne`, without the id, which a
    /// replacement cannot change.
    replace,
    /// A document of the server, read into the model or a projection of
    /// it: the id is `_id`.
    read,
};

/// The keys of the top-level fields of `P`, which is the model `T` or a
/// projection of it, where they are not the Zig names: `_id` for the id
/// (none, so not written, with `.replace`), and the names of
/// `odm_schema.names`.
pub fn keys(comptime T: type, comptime P: type, comptime mode: Mode) []const bson.FieldKey {
    return comptime keysOf(T, P, mode);
}

fn keysOf(comptime T: type, comptime P: type, comptime mode: Mode) []const bson.FieldKey {
    @setEvalBranchQuota(schema.eval_quota);
    schema.check(T);
    var out: []const bson.FieldKey = &.{};
    for (@typeInfo(P).@"struct".field_names) |name| {
        const is_id = std.mem.eql(u8, name, schema.idName(T));
        const key: ?[]const u8 = if (is_id and mode == .replace) null else schema.keyOf(T, name);
        if (key == null or !std.mem.eql(u8, key.?, name)) out = out ++ &[_]bson.FieldKey{.{ .field = name, .key = key }};
    }
    return out;
}

/// The document of `value.*` for `mode`, without its null optionals, in
/// `allocator`; free it with `deinit`. `error.EncodeFailed`: a string is
/// not UTF-8, a `bson.RawDocument` in it is not valid, or documents nest
/// deeper than BSON allows.
pub fn encode(comptime T: type, allocator: Allocator, value: *const T, comptime mode: Mode) error{ EncodeFailed, OutOfMemory }!bson.OwnedDocument {
    return bson.encodeKeyed(allocator, value.*, comptime keys(T, T, mode), .{ .skip_nulls = true }) catch |err| switch (err) {
        error.InvalidBson => error.EncodeFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The value of `P`, the model `T` or a projection of it, that the
/// document `raw` holds; its strings and lists live in `arena`. A field
/// that the document lacks takes its default value, an optional null.
/// `error.DecodeFailed`: the document does not fit `P`; `d.cause` is the
/// decoder's error (`MissingField`, `WrongType`, `Overflow`, …) and
/// `d.path()` the BSON keys of the field, "address.city". The other
/// fields of `d` stay.
pub fn decode(comptime T: type, comptime P: type, arena: Allocator, raw: bson.RawDocument, d: *Diagnostics) error{ InvalidBson, DecodeFailed, OutOfMemory }!P {
    var where: bson.DecodeDiagnostics = .{};
    return bson.decodeKeyed(P, comptime keys(T, P, .read), arena, raw, .{ .diagnostics = &where }) catch |err| switch (err) {
        error.InvalidBson => error.InvalidBson,
        error.OutOfMemory => error.OutOfMemory,
        else => |cause| {
            d.cause = cause;
            d.setPath(where.path());
            return error.DecodeFailed;
        },
    };
}

/// The model `T` of the document of an insert and the id that odm made or
/// that the application gave.
pub fn fromInsert(comptime T: type, doc: schema.Insert(T), id: schema.Id(T)) T {
    const id_name = comptime schema.idName(T);
    if (comptime schema.idKind(T) != .object_id) {
        var value = doc;
        @field(value, id_name) = id;
        return value;
    }
    var value: T = undefined;
    inline for (@typeInfo(schema.Insert(T)).@"struct".field_names) |name| {
        @field(value, name) = @field(doc, name);
    }
    @field(value, id_name) = id;
    return value;
}
