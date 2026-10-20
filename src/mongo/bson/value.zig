//! The values of BSON: `Value`, the element `Element` and the type byte
//! `Type`.

const std = @import("std");
const bson = @import("../bson.zig");

/// The type byte of a BSON element.
pub const Type = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    /// Deprecated: read, never written.
    undefined = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    date_time = 0x09,
    null = 0x0a,
    regex = 0x0b,
    /// Deprecated: read, never written.
    db_pointer = 0x0c,
    javascript = 0x0d,
    /// Deprecated: read, never written.
    symbol = 0x0e,
    /// Deprecated: read, never written.
    javascript_with_scope = 0x0f,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    min_key = 0xff,
    max_key = 0x7f,
};

/// The value of one element. Strings, binary data and documents are
/// slices into the document they were read from and live as long as it.
pub const Value = union(Type) {
    double: f64,
    /// UTF-8 by the spec; a reader does not check it.
    string: []const u8,
    document: bson.RawDocument,
    /// A document whose keys are "0", "1", …; read it as one.
    array: bson.RawDocument,
    binary: bson.Binary,
    undefined,
    object_id: bson.ObjectId,
    boolean: bool,
    date_time: bson.DateTime,
    null,
    regex: bson.Regex,
    db_pointer: bson.DbPointer,
    javascript: []const u8,
    symbol: []const u8,
    javascript_with_scope: bson.JavaScriptWithScope,
    int32: i32,
    timestamp: bson.Timestamp,
    int64: i64,
    decimal128: bson.Decimal128,
    min_key,
    max_key,

    /// The number as an i64: an int32, an int64, or a double that holds
    /// an integer of i64 exactly. The server may send a count or a flag as
    /// any of the three.
    pub fn asI64(v: Value) NumberError!i64 {
        return switch (v) {
            .int32 => |n| n,
            .int64 => |n| n,
            .double => |d| {
                // A fraction, NaN or an infinity has no integer.
                if (!std.math.isFinite(d) or @trunc(d) != d) return error.NotAnInteger;
                if (d < -0x1p63 or d >= 0x1p63) return error.Overflow;
                return @intFromFloat(d);
            },
            else => error.WrongType,
        };
    }

    /// The number as an f64: a double as it is, NaN and infinities
    /// included, or an int32 or int64, an int64 rounded to the nearest
    /// double. The server sends `ok` as a double or as an integer.
    pub fn asF64(v: Value) NumberError!f64 {
        return switch (v) {
            .double => |d| d,
            .int32 => |n| @floatFromInt(n),
            .int64 => |n| @floatFromInt(n),
            else => error.WrongType,
        };
    }
};

/// What `Value.asI64` and `Value.asF64` refuse.
pub const NumberError = error{
    /// The value is not a double, an int32 or an int64.
    WrongType,
    /// A double with a fraction, NaN or an infinity, asked for as an integer.
    NotAnInteger,
    /// A double beyond the range of i64.
    Overflow,
};

/// One element of a document: its key and its value.
pub const Element = struct {
    /// A slice into the document, without the terminating 0.
    key: []const u8,
    value: Value,
};
