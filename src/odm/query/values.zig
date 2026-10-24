//! The rules that the literals of queries share — filters, sorts and
//! updates: which values a field takes, how a literal of conditions is told
//! from a value of a field, how the fields of a literal that are known at
//! compile time are read, how a checked value is written as a value of its
//! field, and how a path steps from a field of a model into the fields of
//! its structs (`At`).
//!
//! A value known only at run time must fit the type of its field without
//! narrowing (`fits`): `u16` for a `u32` field, never `u64`. A value known
//! at compile time is checked by the value itself (`comptimeProblem`): 300
//! is out of the range of a `u8`, `.actve` is not a tag of the enum, a
//! string literal must be UTF-8. Either way the value goes into BSON as a
//! value of the field's type, as the codec of models writes it: a number
//! for a `u32` field is always an int64.

const std = @import("std");
const bson = @import("mongo-bson");
const v = @import("validator");
const schema = @import("../model/schema.zig");
const Builder = bson.Builder;
const Unwrap = schema.Unwrap;
const ListItem = schema.ListItem;

/// Whether a value of `V` is a literal of conditions on a field of type
/// `S` — `.{ .city = "Paris" }`, `.{ .gte = 18 }`, `.{}` — and not a value
/// of `S` itself or of `?S`. A tuple with items is a list, and the types of
/// BSON are values of their own.
pub fn isLiteral(comptime V: type, comptime S: type) bool {
    if (V == S or V == ?S or bson.codec.check.isSpecial(V)) return false;
    return switch (@typeInfo(V)) {
        .@"struct" => |info| !info.is_tuple or info.field_names.len == 0,
        else => false,
    };
}

/// Whether the field `name` of the literal type `V` is known at compile
/// time: its value is then part of the type, and `comptimeValue` reads it.
/// The items of a tuple are its fields "0", "1", ….
pub fn isComptime(comptime V: type, comptime name: []const u8) bool {
    return @typeInfo(V).@"struct".field_attrs[std.meta.fieldIndex(V, name).?].@"comptime";
}

/// The value of the field `name` of the literal type `V`, which
/// `isComptime` says is known at compile time.
pub fn comptimeValue(comptime V: type, comptime name: []const u8) @FieldType(V, name) {
    const info = @typeInfo(V).@"struct";
    const i = std.meta.fieldIndex(V, name).?;
    // Not `defaultValue`: its `?FieldType` cannot be built for the type of
    // `null`.
    const value: *const info.field_types[i] = @ptrCast(@alignCast(info.field_attrs[i].default_value_ptr.?));
    return value.*;
}

/// Whether a value of type `V`, known at run time, fits a field of type
/// `F` without narrowing (design §5.8, "Values"):
///
/// - the same type;
/// - an integer of the same signedness and no wider, or an unsigned one
///   narrower than a signed `F`: `u16` for `i32`, `u32` for `i64`;
/// - `f64` only for `f64`;
/// - for a string, `[]u8`, `[:0]const u8` and pointers to arrays of `u8`;
/// - for an enum, a special type of BSON or a struct: that type only;
/// - for `?X`: a value that fits `X`, or a `?Y` whose `Y` fits `X`;
/// - for a list `[]const E`: a slice, an array, a pointer to an array or a
///   tuple of items that fit `E`; for `[N]E` only those of `N` items, so
///   never a slice. A string is not a list.
///
/// A value known at compile time is checked by `comptimeFits` and
/// `comptimeProblem` instead.
pub fn fits(comptime V: type, comptime F: type) bool {
    return comptime fitsType(V, F);
}

fn fitsType(comptime V: type, comptime F: type) bool {
    if (V == F) return true;
    if (@typeInfo(F) == .optional) {
        const X = @typeInfo(F).optional.child;
        if (@typeInfo(V) == .optional) return fitsType(@typeInfo(V).optional.child, X);
        return fitsType(V, X);
    }
    if (@typeInfo(V) == .optional) return false;
    if (bson.codec.check.isSpecial(F) or schema.isDocument(F)) return false;
    return switch (@typeInfo(F)) {
        .int => |to| switch (@typeInfo(V)) {
            .int => |from| intFits(from, to),
            else => false,
        },
        .array, .pointer => if (F == []const u8) isString(V) else listFits(V, F),
        else => false,
    };
}

fn intFits(comptime from: std.lang.Type.Int, comptime to: std.lang.Type.Int) bool {
    if (from.signedness == to.signedness) return from.bits <= to.bits;
    return from.signedness == .unsigned and from.bits < to.bits;
}

/// Whether `V` is a string: a slice of `u8` or a pointer to an array of
/// `u8`, which coerce to `[]const u8`.
pub fn isString(comptime V: type) bool {
    const info = switch (@typeInfo(V)) {
        .pointer => |info| info,
        else => return false,
    };
    if (info.attrs.@"volatile") return false;
    return switch (info.size) {
        .slice => info.child == u8,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// The tuple whose fields are the items of a list given as a tuple, or as
/// a pointer to one (`&.{ 1, 2 }`); null for any other type. `.{}` is the
/// empty tuple.
pub fn TupleOf(comptime V: type) ?type {
    return switch (@typeInfo(V)) {
        .@"struct" => |info| if (info.is_tuple) V else null,
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) == .@"struct" and @typeInfo(info.child).@"struct".is_tuple) info.child else null,
        else => null,
    };
}

/// Whether a value of `V` is a list: a tuple, a slice, an array, or a
/// pointer to an array or a tuple; a string is not.
pub fn isList(comptime V: type) bool {
    if (isString(V)) return false;
    if (TupleOf(V) != null) return true;
    return switch (@typeInfo(V)) {
        .array => true,
        .pointer => |info| switch (info.size) {
            .slice => true,
            .one => @typeInfo(info.child) == .array,
            else => false,
        },
        else => false,
    };
}

/// The item type and the length (null for a slice) of a list that is not a
/// tuple, or null.
fn itemsOf(comptime V: type) ?struct { type, ?usize } {
    if (isString(V)) return null;
    return switch (@typeInfo(V)) {
        .array => |array| .{ array.child, array.len },
        .pointer => |info| switch (info.size) {
            .slice => .{ info.child, null },
            .one => switch (@typeInfo(info.child)) {
                .array => |array| .{ array.child, array.len },
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

/// The length of the list type `F`: `N` for `[N]E`, null for a slice.
fn lengthOf(comptime F: type) ?usize {
    return switch (@typeInfo(F)) {
        .array => |array| array.len,
        else => null,
    };
}

fn listFits(comptime V: type, comptime F: type) bool {
    const E = ListItem(F) orelse return false;
    if (TupleOf(V)) |Tuple| {
        const names = @typeInfo(Tuple).@"struct".field_names;
        if (lengthOf(F)) |n| if (names.len != n) return false;
        for (names) |name| {
            const Item = @FieldType(Tuple, name);
            const ok = if (isComptime(Tuple, name)) comptimeFits(Item, E) and comptimeProblem(E, comptimeValue(Tuple, name)) == null else fitsType(Item, E);
            if (!ok) return false;
        }
        return true;
    }
    const items = itemsOf(V) orelse return false;
    if (lengthOf(F)) |n| if (items[1] != n) return false;
    return fitsType(items[0], E);
}

/// Whether a value of type `V` that is known at compile time may be a value
/// of `F`, before `comptimeProblem` looks at the value itself: what `fits`
/// takes, and an integer of any type for an integer field, an integer or a
/// float literal for `f64`, an enum literal for an enum, null for an
/// optional, a list of such items for a list.
pub fn comptimeFits(comptime V: type, comptime F: type) bool {
    return comptime comptimeFitsType(V, F);
}

fn comptimeFitsType(comptime V: type, comptime F: type) bool {
    if (fitsType(V, F)) return true;
    if (@typeInfo(F) == .optional) {
        const X = @typeInfo(F).optional.child;
        if (V == @TypeOf(null)) return true;
        if (@typeInfo(V) == .optional) return comptimeFitsType(@typeInfo(V).optional.child, X);
        return comptimeFitsType(V, X);
    }
    if (bson.codec.check.isSpecial(F) or schema.isDocument(F)) return false;
    return switch (@typeInfo(F)) {
        .int => V == comptime_int or @typeInfo(V) == .int,
        .float => F == f64 and (V == comptime_float or V == comptime_int),
        .@"enum" => @typeInfo(V) == .enum_literal,
        .array, .pointer => F != []const u8 and listKind(V, F),
        else => false,
    };
}

/// Whether a list known at compile time has items that may be items of the
/// list type `F`, and as many as `F` holds.
fn listKind(comptime V: type, comptime F: type) bool {
    const E = ListItem(F) orelse return false;
    if (TupleOf(V)) |Tuple| {
        const info = @typeInfo(Tuple).@"struct";
        if (lengthOf(F)) |n| if (info.field_names.len != n) return false;
        for (info.field_types) |Item| {
            if (!comptimeFitsType(Item, E)) return false;
        }
        return true;
    }
    const items = itemsOf(V) orelse return false;
    if (lengthOf(F)) |n| if (items[1] != n) return false;
    return comptimeFitsType(items[0], E);
}

/// What is wrong with `value`, known at compile time, as a value of `F`,
/// whose kind `comptimeFits` has taken; null when nothing is. The text
/// follows "{M}.{path} " in a compile error: "is u32, and -1 is out of its
/// range", "is User.Status, which has no tag 'actve'; did you mean
/// 'active'?", "is []const u8, and its value is not UTF-8". For a list it
/// is the problem of the first item that has one.
pub fn comptimeProblem(comptime F: type, comptime value: anytype) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(schema.eval_quota);
        const V = @TypeOf(value);
        if (@typeInfo(F) == .optional) {
            const X = @typeInfo(F).optional.child;
            if (V == @TypeOf(null)) return null;
            if (@typeInfo(V) == .optional) return if (value) |present| comptimeProblem(X, present) else null;
            return comptimeProblem(X, value);
        }
        switch (@typeInfo(F)) {
            .int => if (V == comptime_int or @typeInfo(V) == .int) {
                if (value < std.math.minInt(F) or value > std.math.maxInt(F)) return outOfRange(F, value);
            },
            // A double holds every integer up to 2^53 exactly.
            .float => if (V == comptime_int) {
                if (value < -(1 << 53) or value > 1 << 53) return outOfRange(F, value);
            } else if (V == comptime_float) {
                if (value < -std.math.floatMax(f64) or value > std.math.floatMax(f64)) return outOfRange(F, value);
            },
            .@"enum" => |info| if (@typeInfo(V) == .enum_literal) {
                const tag = @tagName(value);
                if (!@hasField(F, tag)) return "is " ++ @typeName(F) ++ ", which has no tag '" ++ tag ++ "'" ++ didYouMean(info.field_names, tag);
            },
            .array, .pointer => if (F == []const u8) {
                if (isString(V) and !std.unicode.utf8ValidateSlice(value)) return "is []const u8, and its value is not UTF-8";
            } else if (ListItem(F)) |E| {
                if (TupleOf(V)) |Tuple| {
                    const items: Tuple = if (@typeInfo(V) == .pointer) value.* else value;
                    for (@typeInfo(Tuple).@"struct".field_names) |name| {
                        if (comptimeProblem(E, @field(items, name))) |problem| return problem;
                    }
                } else if (itemsOf(V) != null) {
                    for (value) |item| {
                        if (comptimeProblem(E, item)) |problem| return problem;
                    }
                }
            },
            else => {},
        }
        return null;
    }
}

fn outOfRange(comptime F: type, comptime value: anytype) []const u8 {
    return std.fmt.comptimePrint("is {s}, and {d} is out of its range", .{ @typeName(F), value });
}

/// "; did you mean 'x'?" when `v.closest` finds a name near `key` among
/// `names`, else "".
pub fn didYouMean(comptime names: []const [:0]const u8, comptime key: []const u8) []const u8 {
    comptime {
        var list: [names.len][]const u8 = undefined;
        for (names, &list) |name, *item| item.* = name;
        const final = list;
        const best = v.closest(&final, key) orelse return "";
        return "; did you mean '" ++ best ++ "'?";
    }
}

/// Stops the build unless the field `name` of the literal type `L` holds a
/// value for `X`: one that `fits` it when it is known at run time, or one
/// whose kind and value fit when it is known at compile time; a list given
/// as a tuple is checked item by item, with "[]" after the path. `what`
/// names the operation, "gte on" or "set of", in the message of a value of
/// another type: "odm: gte on User.age needs a u32; got *const [2:0]u8".
/// The message of a value that does not fit is "odm: {M}.{path} " and the
/// text of `comptimeProblem`.
pub fn checkValue(comptime what: []const u8, comptime M: []const u8, comptime path: []const u8, comptime X: type, comptime L: type, comptime name: []const u8) void {
    comptime {
        const V = @FieldType(L, name);
        if (TupleOf(V)) |Tuple| if (ListItem(Unwrap(X))) |E| {
            if (lengthOf(Unwrap(X))) |n| if (@typeInfo(Tuple).@"struct".field_names.len != n) typeError(what, M, path, X, V);
            for (@typeInfo(Tuple).@"struct".field_names) |item| checkValue(what, M, path ++ "[]", E, Tuple, item);
            return;
        };
        if (isComptime(L, name)) {
            if (!comptimeFitsType(V, X)) typeError(what, M, path, X, V);
            if (comptimeProblem(X, comptimeValue(L, name))) |problem| @compileError("odm: " ++ M ++ "." ++ path ++ " " ++ problem);
        } else if (!fitsType(V, X)) typeError(what, M, path, X, V);
    }
}

/// Stops the build: the value is of a type that `X` does not take.
pub fn typeError(comptime what: []const u8, comptime M: []const u8, comptime path: []const u8, comptime X: type, comptime V: type) noreturn {
    @compileError("odm: " ++ what ++ " " ++ M ++ "." ++ path ++ " needs a " ++ @typeName(Unwrap(X)) ++ "; got " ++ @typeName(V));
}

/// Writes `value`, which `checkValue` took for `X`, under `key` as a value
/// of `X`: a number as `X`'s integer or double, an enum literal as the
/// name of the tag, a list item by item, a struct as a document without
/// its null optionals, null as null.
pub fn writeValue(b: *Builder, key: []const u8, comptime X: type, value: anytype) Builder.Error!void {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return b.putNull(key);
    if (@typeInfo(X) == .optional) {
        const Child = @typeInfo(X).optional.child;
        if (@typeInfo(V) == .optional) {
            return if (value) |present| writeValue(b, key, Child, present) else b.putNull(key);
        }
        return writeValue(b, key, Child, value);
    }
    if (comptime X != []const u8 and ListItem(X) != null) {
        const E = ListItem(X).?;
        try b.beginArray(key);
        if (comptime TupleOf(V)) |Tuple| {
            const items: Tuple = if (@typeInfo(V) == .pointer) value.* else value;
            inline for (@typeInfo(Tuple).@"struct".field_names) |name| try writeValue(b, "", E, @field(items, name));
        } else {
            for (value) |item| try writeValue(b, "", E, item);
        }
        return b.end();
    }
    // A typed integer known at compile time may be wider than X; its value
    // fits, as the check saw.
    const converted: X = if (comptime @typeInfo(X) == .int and @typeInfo(V) == .int) @intCast(value) else value;
    try bson.codec.writeElement(b, key, converted, .{ .skip_nulls = true });
}

/// Where a condition, a key of a sort or a change of an update stands: a
/// path of the fields of a model.
pub const At = struct {
    /// The model.
    T: type,
    /// The Zig names of the fields on the way, joined by '.', for the
    /// messages: "profile.city"; "items[]" names an item of a list.
    path: []const u8,
    /// The key that the condition goes under in its document: the BSON
    /// path, such as "createdAt" or "profile.city"; inside `$elemMatch` the
    /// path in the item, "" for the item itself.
    key: []const u8,
    /// The type of the field, as declared.
    F: type,
    /// Whether a document may lack the field: it is optional, or a field on
    /// the way is.
    optional: bool,
};

/// "{M}.{path}", the subject of the messages about the field at `at`.
pub fn subject(comptime at: At) []const u8 {
    return @typeName(at.T) ++ "." ++ at.path;
}

/// The top-level field `name` of the model `T`, whose key is its BSON name
/// (`_id` for the id). Stops the build when `T` has no such field.
pub fn top(comptime T: type, comptime name: []const u8) At {
    if (!@hasField(T, name)) @compileError("odm: " ++ @typeName(T) ++ " has no field '" ++ name ++ "'" ++ didYouMean(@typeInfo(T).@"struct".field_names, name));
    const F = @FieldType(T, name);
    return .{ .T = T, .path = name, .key = schema.keyOf(T, name), .F = F, .optional = @typeInfo(F) == .optional };
}

/// The field `name` of the struct of the field at `at`, which `Fields`
/// gives, on a path through it. Stops the build when the struct has no
/// such field.
pub fn field(comptime at: At, comptime name: []const u8) At {
    const S = Fields(at.F).?;
    if (!@hasField(S, name)) @compileError("odm: " ++ subject(at) ++ " has no field '" ++ name ++ "'" ++ didYouMean(@typeInfo(S).@"struct".field_names, name));
    return inner(at, S, name);
}

/// The struct whose fields a literal on a field of type `F` names as paths:
/// the struct of the field, or the struct of the items of a list; null for
/// any other field.
pub fn Fields(comptime F: type) ?type {
    const S = Unwrap(F);
    if (schema.isDocument(S)) return S;
    const Item = ListItem(S) orelse return null;
    return if (schema.isDocument(Unwrap(Item))) Unwrap(Item) else null;
}

/// The declared type of the items of the field at `at`, when it is a list.
pub fn ItemOf(comptime at: At) ?type {
    return ListItem(Unwrap(at.F));
}

/// The field `name` of `S`, the struct of the field at `at`, on a path
/// through it: a key of BSON that goes on with its Zig name.
pub fn inner(comptime at: At, comptime S: type, comptime name: []const u8) At {
    const F = @FieldType(S, name);
    const items_optional = if (ItemOf(at)) |Item| @typeInfo(Item) == .optional else false;
    return .{
        .T = at.T,
        .path = at.path ++ "." ++ name,
        .key = if (at.key.len == 0) name else at.key ++ "." ++ name,
        .F = F,
        .optional = at.optional or items_optional or @typeInfo(F) == .optional,
    };
}
