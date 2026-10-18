//! The BSON types that Zig has no type for, apart from `ObjectId` and
//! `Decimal128`, which have files of their own.

const std = @import("std");
const bson = @import("../bson.zig");

/// A UTC instant: milliseconds since the Unix epoch, BSON's datetime.
pub const DateTime = struct {
    milliseconds: i64,
};

/// The timestamp of MongoDB's replication: seconds since the Unix epoch
/// and an ordinal within the second. For a moment in time in your own
/// documents, use `DateTime`.
pub const Timestamp = struct {
    seconds: u32,
    increment: u32,
};

/// Bytes with a subtype that says what they are.
pub const Binary = struct {
    subtype: Subtype,
    bytes: []const u8,

    pub const Subtype = enum(u8) {
        generic = 0x00,
        function = 0x01,
        /// The old generic subtype. Its data begins with a second length,
        /// which readers strip and writers add: `bytes` never holds it.
        binary_old = 0x02,
        uuid_old = 0x03,
        uuid = 0x04,
        md5 = 0x05,
        encrypted = 0x06,
        column = 0x07,
        sensitive = 0x08,
        vector = 0x09,
        /// The first of 0x80–0xFF, the subtypes applications define.
        user_defined = 0x80,
        _,
    };
};

/// A regular expression. Neither part may hold a 0 byte.
pub const Regex = struct {
    pattern: []const u8,
    /// Letters such as "i" and "m".
    options: []const u8,
};

/// Deprecated, read but never written: a namespace and an id.
pub const DbPointer = struct {
    namespace: []const u8,
    id: bson.ObjectId,
};

/// Deprecated, read but never written: JavaScript code with the values of
/// its variables.
pub const JavaScriptWithScope = struct {
    code: []const u8,
    scope: bson.RawDocument,
};
