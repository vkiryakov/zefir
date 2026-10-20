//! Writing Zig values as BSON by their types: `bson.encode` and
//! `Builder.put`. `bson.literal` writes the same bytes at compile time.

const std = @import("std");
const bson = @import("../bson.zig");
const check = @import("check.zig");
const Builder = bson.Builder;

pub const EncodeOptions = struct {
    /// Leave out the fields whose value is null, instead of writing BSON
    /// null; the items of arrays are written all the same. Drivers write
    /// their commands so, with optional fields for optional parts. Keep it
    /// off for filters: there a field left out matches every document, and
    /// `.{ .email = maybe_email }` with null would match them all.
    skip_nulls: bool = false,
};

/// The document that `value` holds, by the types of its fields:
///
/// | Zig | BSON |
/// |---|---|
/// | `bool` | boolean |
/// | `i8`–`i32`, `u8`–`u16` (every integer type whose values fit int32) | int32 |
/// | `i33`–`i64`, `u32`–`u63` | int64 |
/// | `f32`, `f64` | double, NaN and the infinities included |
/// | `[]const u8` | string, which must be UTF-8 |
/// | an exhaustive enum | string: the name of its tag |
/// | `?T` | BSON null, or the value; `.skip_nulls` leaves null fields out |
/// | a struct | document, with the fields in their order |
/// | `[]const T`, `[N]T` | array |
/// | `bson.RawDocument`, `bson.OwnedDocument`, `bson.Value` and the special types | as they are |
///
/// Anonymous literals are written too, for filters, updates and commands:
/// `.{ .age = .{ .@"$gte" = 18 }, .status = .active }`. In them an integer
/// is int32 when it fits and int64 otherwise, a float is a double, a string
/// literal a string, `null` is null and an enum literal the name of its
/// tag. A tuple, `.{ a, b }` or `&.{ a, b }`, is an array: a pipeline, the
/// list of `$in`. `.{}` is the empty document `{}`; `&.{}` an empty array.
/// Comptime fields are written like the others.
///
/// `value` itself is a struct, or a `RawDocument` or an `OwnedDocument`,
/// which is checked and copied. Every other type stops the build with the
/// path of the field: `u64`, `usize`, `isize` and the C integers, floats
/// other than f32 and f64, non-exhaustive enums, unions, pointers other
/// than slices and lists, `??T`, and types that hold themselves.
///
/// `error.InvalidBson`: a string is not UTF-8, a document in a field fails
/// `RawDocument.validate`, a `Value` is of a deprecated type, a regular
/// expression holds a 0 byte, or more than `bson.max_depth` documents and
/// arrays nest inside one another. The document is in `allocator`; free it
/// with `deinit`.
pub fn encode(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) Builder.Error!bson.OwnedDocument {
    const T = @TypeOf(value);
    if (comptime check.document(T, .encode)) |problem| @compileError("bson.encode: " ++ problem);
    if (T == bson.RawDocument or T == bson.OwnedDocument) {
        const doc: bson.RawDocument = if (T == bson.OwnedDocument) value.raw() else value;
        try doc.validate();
        return doc.dupe(allocator);
    }
    var b: Builder = .init(allocator);
    defer b.deinit();
    try writeFields(&b, value, options);
    return b.finish();
}

/// How the codec writes a value of type `T`.
pub const Shape = enum {
    /// One BSON value: a number, a string, a special type, a document
    /// given as it is.
    scalar,
    /// A struct, `.{}` among them: a document of its fields.
    document,
    /// A tuple of values, or a pointer to one: an array of its items.
    tuple,
    /// A slice, an array, or a pointer to an array: an array of its items.
    list,
    /// Null or the value.
    optional,
};

pub fn shape(comptime T: type) Shape {
    if (check.isSpecial(T)) return .scalar;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple and info.field_names.len > 0) .tuple else .document,
        .optional => .optional,
        .array => .list,
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8) .scalar else .list,
            // A pointer to an array or a tuple (the check refuses others).
            else => switch (@typeInfo(info.child)) {
                .array => |array| if (array.child == u8) .scalar else .list,
                else => .tuple,
            },
        },
        else => .scalar,
    };
}

/// Writes the fields of the struct `value` into the document open in `b`.
pub fn writeFields(b: *Builder, value: anytype, options: EncodeOptions) Builder.Error!void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        const field = @field(value, name);
        if (!(options.skip_nulls and isNull(field))) try writeElement(b, name, field, options);
    }
}

/// Writes `value` under `key`; in an array the key is "".
pub fn writeElement(b: *Builder, key: []const u8, value: anytype, options: EncodeOptions) Builder.Error!void {
    switch (comptime shape(@TypeOf(value))) {
        .scalar => try b.putValue(key, try scalar(value)),
        .document => {
            try b.beginDocument(key);
            try writeFields(b, value, options);
            try b.end();
        },
        .tuple => {
            const items = if (@typeInfo(@TypeOf(value)) == .pointer) value.* else value;
            try b.beginArray(key);
            inline for (@typeInfo(@TypeOf(items)).@"struct".field_names) |name| {
                try writeElement(b, "", @field(items, name), options);
            }
            try b.end();
        },
        .list => {
            try b.beginArray(key);
            for (value) |item| try writeElement(b, "", item, options);
            try b.end();
        },
        .optional => if (value) |inner| try writeElement(b, key, inner, options) else try b.putNull(key),
    }
}

/// The BSON value of a value whose shape is `.scalar`.
pub fn scalar(value: anytype) bson.Error!bson.Value {
    const T = @TypeOf(value);
    if (T == bson.Value) {
        if (value == .string) try utf8(value.string);
        return value;
    }
    if (T == bson.RawDocument) return .{ .document = value };
    if (T == bson.OwnedDocument) return .{ .document = value.raw() };
    if (T == bson.ObjectId) return .{ .object_id = value };
    if (T == bson.DateTime) return .{ .date_time = value };
    if (T == bson.Timestamp) return .{ .timestamp = value };
    if (T == bson.Binary) return .{ .binary = value };
    if (T == bson.Decimal128) return .{ .decimal128 = value };
    if (T == bson.Regex) return .{ .regex = value };
    if (T == bson.Null) return .null;
    if (T == bson.MinKey) return .min_key;
    if (T == bson.MaxKey) return .max_key;
    switch (@typeInfo(T)) {
        .bool => return .{ .boolean = value },
        .int => |int| {
            // int32 when every value of the type fits it.
            const fits_int32 = int.bits <= @as(u16, if (int.signedness == .signed) 32 else 31);
            return if (fits_int32) .{ .int32 = value } else .{ .int64 = value };
        },
        .comptime_int => return comptime integerLiteral(value),
        .float, .comptime_float => return .{ .double = value },
        .@"enum" => return .{ .string = @tagName(value) },
        .enum_literal => {
            try utf8(@tagName(value));
            return .{ .string = @tagName(value) };
        },
        .null => return .null,
        .pointer => {
            try utf8(value);
            return .{ .string = value };
        },
        else => comptime unreachable,
    }
}

fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        .null => true,
        else => false,
    };
}

/// An integer literal: int32 when it fits, otherwise int64.
fn integerLiteral(comptime n: comptime_int) bson.Value {
    if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) return .{ .int32 = n };
    if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) return .{ .int64 = n };
    @compileError(std.fmt.comptimePrint("bson: the integer {d} does not fit int64", .{n}));
}

fn utf8(text: []const u8) bson.Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidBson;
}
