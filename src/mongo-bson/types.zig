//! The BSON types that Zig has no type for, apart from `ObjectId` and
//! `Decimal128`, which have files of their own.

const std = @import("std");
const bson = @import("root.zig");

/// A UTC instant: milliseconds since the Unix epoch, BSON's datetime.
pub const DateTime = struct {
    milliseconds: i64,

    /// Now, from the real-time clock of `io`: wall-clock time, which may
    /// jump when the system clock is set. Measure durations with
    /// `std.Io.Clock.awake` instead.
    pub fn now(io: std.Io) DateTime {
        return .{ .milliseconds = std.Io.Clock.real.now(io).toMilliseconds() };
    }
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

/// BSON null as a type: a field of this type always holds null. A `Value`
/// holds null as `.null`.
pub const Null = struct {};

/// The value below every other BSON value; queries and index bounds use
/// it as minus infinity. A `Value` holds it as `.min_key`.
pub const MinKey = struct {};

/// The value above every other BSON value. A `Value` holds it as
/// `.max_key`.
pub const MaxKey = struct {};

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
