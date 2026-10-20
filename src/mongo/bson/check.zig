//! The comptime check of the types that the typed codec takes: one walk
//! over a type, which names the first field that does not fit and says what
//! to write instead. `bson.encode`, `bson.literal`, `Builder.put` and
//! `bson.decode` stop the build with its message.

const std = @import("std");
const bson = @import("../bson.zig");

/// Which way the codec goes.
pub const Direction = enum { encode, decode };

/// Why `T` cannot be the document that `encode` writes or `decode` fills,
/// as the end of a compile error, or null when it can.
pub fn document(comptime T: type, comptime direction: Direction) ?[]const u8 {
    return comptime documentProblem(T, direction);
}

/// Why a value of type `T` cannot be written into a document, or read from
/// one, or null.
pub fn value(comptime T: type, comptime direction: Direction) ?[]const u8 {
    return comptime walk(T, "", direction, &.{});
}

/// Whether the codec writes `T` as the BSON value of its own: the documents
/// and values of `mongo.bson` and its special types.
pub fn isSpecial(comptime T: type) bool {
    inline for (.{
        bson.RawDocument, bson.OwnedDocument,       bson.Value,  bson.ObjectId,
        bson.DateTime,    bson.Timestamp,           bson.Binary, bson.Decimal128,
        bson.Regex,       bson.Null,                bson.MinKey, bson.MaxKey,
        bson.DbPointer,   bson.JavaScriptWithScope,
    }) |Special| {
        if (T == Special) return true;
    }
    return false;
}

fn documentProblem(comptime T: type, comptime direction: Direction) ?[]const u8 {
    const not_a_document = switch (direction) {
        .encode => "a document is a struct with named fields, such as .{ .name = name }, or a bson.RawDocument; got ",
        .decode => "decode fills a struct with named fields; got ",
    } ++ @typeName(T);
    if (direction == .encode and (T == bson.RawDocument or T == bson.OwnedDocument)) return null;
    if (isSpecial(T)) return not_a_document;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (direction == .encode and info.is_tuple and info.field_names.len > 0) {
                return "a tuple is an array, not a document: give its values names, such as .{ .a = x }";
            }
            return walk(T, "", direction, &.{});
        },
        else => return not_a_document,
    }
}

/// The problem of `T`, which sits at `path` ("" for the value itself).
/// `outer` lists the structs that hold `T`, to find a type that holds
/// itself.
fn walk(comptime T: type, comptime path: []const u8, comptime direction: Direction, comptime outer: []const type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const is = subject(path) ++ " is " ++ @typeName(T);
    if (T == bson.DbPointer or T == bson.JavaScriptWithScope) {
        return if (direction == .decode) null else is ++ ", a deprecated type: it is read, never written";
    }
    if (T == bson.OwnedDocument and direction == .decode) return is ++ ": decode into a bson.RawDocument, whose bytes live in the arena";
    if (isSpecial(T)) return null;
    switch (@typeInfo(T)) {
        .bool => return null,
        .int => |int| return integer(T, int, is),
        // The types of the values of anonymous literals: .{ .age = 30 }.
        .comptime_int, .comptime_float, .enum_literal, .null => return switch (direction) {
            .encode => null,
            .decode => is ++ ", the type of a literal: decode needs a type such as i64, f64, []const u8 or an enum",
        },
        .float => return if (T == f32 or T == f64) null else is ++ ": a BSON double is an f64; use f64 or f32",
        .@"enum" => |info| {
            if (info.mode == .nonexhaustive) return is ++ ", a non-exhaustive enum: a value without a tag has no name to write; make the enum exhaustive";
            for (info.field_names) |tag| {
                if (!std.unicode.utf8ValidateSlice(tag)) return is ++ ": the name of one of its tags is not UTF-8";
            }
            return null;
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .optional) return is ++ ": BSON null cannot tell the two nulls apart";
            return walk(info.child, path, direction, outer);
        },
        .pointer => |info| return pointer(T, info, path, direction, outer),
        .array => |info| {
            if (direction == .decode and info.sentinel_ptr != null) return is ++ ": decode fills arrays without a sentinel";
            return walk(info.child, path ++ "[]", direction, outer);
        },
        .@"struct" => |info| return structure(T, info, path, direction, outer),
        .@"union" => return is ++ ": unions are not supported; a field of any BSON type is a bson.Value",
        else => return is ++ ", which has no BSON type",
    }
}

fn subject(comptime path: []const u8) []const u8 {
    return if (path.len == 0) "the value" else "field '" ++ path ++ "'";
}

fn integer(comptime T: type, comptime int: std.lang.Type.Int, comptime is: []const u8) ?[]const u8 {
    if (T == usize or T == isize) return is ++ ", whose size depends on the target: use i64 or i32";
    // c_int and the other C types are distinct types of a size that
    // depends on the target too.
    if (T != @Int(int.signedness, int.bits)) return is ++ ", whose size depends on the target: use an integer of a fixed width, such as i32";
    if (int.signedness == .unsigned and int.bits == 64) return is ++ ", which BSON has no type for: its integers are signed; use i64";
    if (int.bits > 64) return is ++ ": BSON integers have at most 64 bits; use i64";
    return null;
}

fn pointer(comptime T: type, comptime info: std.lang.Type.Pointer, comptime path: []const u8, comptime direction: Direction, comptime outer: []const type) ?[]const u8 {
    const is = subject(path) ++ " is " ++ @typeName(T);
    switch (info.size) {
        .slice => {
            if (direction == .decode) {
                const plain = "[]const " ++ @typeName(info.child);
                if (!info.attrs.@"const") return is ++ ": decode gives const slices; use " ++ plain;
                if (info.sentinel_ptr != null) return is ++ ": decode gives slices without a sentinel; use " ++ plain;
            }
            // []const u8 is a string.
            if (info.child == u8) return null;
            return walk(info.child, path ++ "[]", direction, outer);
        },
        .many, .c => return is ++ ", which has no length: pass a slice",
        .one => if (direction == .decode) {
            return is ++ ": decode fills values, not pointers; use " ++ @typeName(info.child);
        } else switch (@typeInfo(info.child)) {
            // &[_]T{ … } is a list; a string literal and &[_]u8{ … } are strings.
            .array => |array| return if (array.child == u8) null else walk(array.child, path ++ "[]", direction, outer),
            // &.{ … } is a list.
            .@"struct" => |child| if (child.is_tuple) return walk(info.child, path, direction, outer),
            else => {},
        },
    }
    return is ++ ": pass the value itself, not a pointer to it";
}

fn structure(comptime T: type, comptime info: std.lang.Type.Struct, comptime path: []const u8, comptime direction: Direction, comptime outer: []const type) ?[]const u8 {
    for (outer) |Outer| {
        if (Outer == T) return subject(path) ++ " is " ++ @typeName(T) ++ " inside itself: a type that holds itself is not supported";
    }
    const inner = outer ++ [_]type{T};
    if (info.is_tuple) {
        if (direction == .decode) return subject(path) ++ " is " ++ @typeName(T) ++ ", a tuple: decode needs the names of fields; use a struct, or a slice for an array";
        // .{} is an empty document; any other tuple is an array of its items.
        for (info.field_types, info.field_attrs, 0..) |Item, attrs, i| {
            const item = std.fmt.comptimePrint("{s}[{d}]", .{ path, i });
            if (constant(Item, attrs, item)) |found| return found;
            if (walk(Item, item, direction, inner)) |found| return found;
        }
        return null;
    }
    for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        const field = if (path.len == 0) name else path ++ "." ++ name;
        if (!std.unicode.utf8ValidateSlice(name)) return subject(path) ++ " is " ++ @typeName(T) ++ ": the name of one of its fields is not UTF-8";
        if (attrs.@"comptime" and direction == .decode) return subject(field) ++ " is a comptime field: decode fills only fields known at run time";
        if (constant(Field, attrs, field)) |found| return found;
        if (walk(Field, field, direction, inner)) |found| return found;
    }
    return null;
}

/// The problem of the value of a comptime field, the field of a literal:
/// an integer beyond int64, an enum literal whose name is not UTF-8.
fn constant(comptime Field: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime path: []const u8) ?[]const u8 {
    if (!attrs.@"comptime") return null;
    switch (@typeInfo(Field)) {
        .comptime_int => {
            const n = attrs.defaultValue(Field).?;
            if (n < std.math.minInt(i64) or n > std.math.maxInt(i64)) {
                return std.fmt.comptimePrint("{s} is {d}, which does not fit int64", .{ subject(path), n });
            }
        },
        .enum_literal => {
            if (!std.unicode.utf8ValidateSlice(@tagName(attrs.defaultValue(Field).?))) {
                return subject(path) ++ " is an enum literal whose name is not UTF-8";
            }
        },
        else => {},
    }
    return null;
}
