//! `bson.encodeKeyed` and `bson.decodeKeyed`: `encode` and `decode` with
//! keys of their own for the top-level fields of a struct, from a list of
//! `bson.FieldKey`s, such as `_id` for a field `id` and `createdAt` for
//! `created_at`. The documents inside keep the names of their Zig fields,
//! which may be any key: `zipCode`, `@"zip-code"`.
//!
//! ```zig
//! const User = struct { id: ?bson.ObjectId = null, name: []const u8, created_at: bson.DateTime };
//! const keys: []const bson.FieldKey = &.{ .{ .field = "id", .key = "_id" }, .{ .field = "created_at", .key = "createdAt" } };
//! const doc = try bson.encodeKeyed(gpa, user, keys, .{ .skip_nulls = true }); // {_id, name, createdAt}
//! defer doc.deinit();
//! const back = try bson.decodeKeyed(User, keys, arena, doc.raw(), .{});
//! ```

const std = @import("std");
const bson = @import("root.zig");
const check = @import("check.zig");
const encoding = @import("encode.zig");
const decoding = @import("decode.zig");

/// The key of a field of a struct in its document, when it is not the name
/// of the field: `.{ .field = "id", .key = "_id" }`. A null key leaves the
/// field out: it is never written, and decode never reads it, so it takes
/// its default value or null.
pub const FieldKey = struct { field: []const u8, key: ?[]const u8 };

/// `bson.encode`, with the keys of the top-level fields of `value` from
/// `keys`: a field that `keys` does not list keeps its name, one with a
/// null key is not written, and the documents inside are written as
/// `encode` writes them. With no keys it is `encode`.
///
/// `keys` is checked when the program compiles: each entry names a field
/// of `value`, once, with a key that is not empty, is UTF-8 and holds no 0
/// byte, and no two fields get one key.
pub fn encodeKeyed(allocator: std.mem.Allocator, value: anytype, comptime keys: []const FieldKey, options: bson.EncodeOptions) bson.Builder.Error!bson.OwnedDocument {
    const T = @TypeOf(value);
    if (comptime check.document(T, .encode)) |problem| @compileError("bson.encodeKeyed: " ++ problem);
    if (comptime keysProblem(T, keys, .encode)) |problem| @compileError("bson.encodeKeyed: keys: " ++ problem);
    if (keys.len == 0) return bson.encode(allocator, value, options);
    var b: bson.Builder = .init(allocator);
    defer b.deinit();
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime keyOf(keys, name)) |key| {
            const field = @field(value, name);
            if (!(options.skip_nulls and encoding.isNull(field))) try encoding.writeElement(&b, key, field, options);
        }
    }
    return b.finish();
}

/// `bson.decode`, with the keys of the top-level fields of `T` from `keys`:
/// each key of the document goes to the field that has it, a field with a
/// null key is not read and takes its default value or null, and
/// `DecodeDiagnostics` names the keys of the document. With no keys it is
/// `decode`.
///
/// `keys` is checked as `encodeKeyed` checks it, and a field that is not
/// read must be optional or have a default value.
pub fn decodeKeyed(comptime T: type, comptime keys: []const FieldKey, arena: std.mem.Allocator, raw: bson.RawDocument, options: bson.DecodeOptions) bson.DecodeError!T {
    if (comptime check.document(T, .decode)) |problem| @compileError("bson.decodeKeyed: " ++ problem);
    if (comptime keysProblem(T, keys, .decode)) |problem| @compileError("bson.decodeKeyed: keys: " ++ problem);
    return decoding.decodeWithKeys(T, keys, arena, raw, options);
}

/// The key of the field `name` by `keys`: the key of its entry, or its
/// name when `keys` does not list it.
pub fn keyOf(comptime keys: []const FieldKey, comptime name: []const u8) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    for (keys) |entry| {
        if (std.mem.eql(u8, entry.field, name)) return entry.key;
    }
    return name;
}

/// The field of `T` that the key `key` of a document goes to by `keys`,
/// or null.
pub fn fieldOf(comptime T: type, comptime keys: []const FieldKey, key: []const u8) ?std.meta.FieldEnum(T) {
    if (keys.len == 0) return std.meta.stringToEnum(std.meta.FieldEnum(T), key);
    const fields = comptime fieldsByKey(T, keys);
    return fields.get(key);
}

fn fieldsByKey(comptime T: type, comptime keys: []const FieldKey) std.StaticStringMap(std.meta.FieldEnum(T)) {
    @setEvalBranchQuota(100_000);
    const Field = std.meta.FieldEnum(T);
    var pairs: []const struct { []const u8, Field } = &.{};
    for (@typeInfo(T).@"struct".field_names) |name| {
        if (keyOf(keys, name)) |key| pairs = pairs ++ .{.{ key, @field(Field, name) }};
    }
    return .initComptime(pairs);
}

/// Why `keys` cannot give the fields of `T` their keys, as the end of a
/// compile error, or null when they can. `check.document` has taken `T`.
fn keysProblem(comptime T: type, comptime keys: []const FieldKey, comptime direction: check.Direction) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    // A document given as it is has no fields to name.
    const names: []const [:0]const u8 = switch (@typeInfo(T)) {
        .@"struct" => |info| if (T == bson.RawDocument or T == bson.OwnedDocument) &.{} else info.field_names,
        else => return null,
    };
    for (keys, 0..) |entry, i| {
        if (!isName(names, entry.field)) return "'" ++ entry.field ++ "' is not a field of " ++ @typeName(T);
        for (keys[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.field, entry.field)) return "'" ++ entry.field ++ "' is listed twice";
        }
        const key = entry.key orelse continue;
        const of = "the key of '" ++ entry.field ++ "'";
        if (key.len == 0) return of ++ " is empty";
        if (std.mem.findScalar(u8, key, 0) != null) return of ++ " holds a NUL byte";
        if (!std.unicode.utf8ValidateSlice(key)) return of ++ " is not UTF-8";
    }
    for (names, 0..) |name, i| {
        const key = keyOf(keys, name) orelse continue;
        for (names[i + 1 ..]) |other| {
            const other_key = keyOf(keys, other) orelse continue;
            if (std.mem.eql(u8, key, other_key)) return "'" ++ name ++ "' and '" ++ other ++ "' both have the key \"" ++ key ++ "\"";
        }
    }
    if (direction == .decode) {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            if (keyOf(keys, name) == null and attrs.defaultValue(Field) == null and @typeInfo(Field) != .optional) {
                return "'" ++ name ++ "' is not read, but it is not optional and has no default";
            }
        }
    }
    return null;
}

fn isName(names: []const [:0]const u8, name: []const u8) bool {
    for (names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}
