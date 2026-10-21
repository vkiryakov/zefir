//! Writes a BSON document into a buffer that grows, and fills in the
//! lengths of its documents when they end.
//!
//! ```zig
//! var b: bson.Builder = .init(gpa);
//! defer b.deinit();
//! try b.putString("name", "Ann");
//! try b.beginArray("tags");
//! try b.putString("", "admin"); // in an array the builder writes the keys
//! try b.end();
//! const doc = try b.finish(); // {"name": "Ann", "tags": ["admin"]}
//! defer doc.deinit();
//! ```
//!
//! `put` writes a value of any type that `bson.encode` takes, a struct or a
//! slice with all that is in it: `try b.put("filter", .{ .age = 30 })`.
//!
//! Keys, strings, codes and regular expressions are UTF-8, as BSON asks,
//! and keys and regular expressions hold no 0 byte. Inside an array the
//! builder numbers the elements itself ("0", "1", …), so the key passed
//! there must be empty.
//! At most `bson.max_depth` documents and arrays nest inside one another,
//! the top-level document included. A call that fails, for any of these
//! reasons or for lack of memory, leaves the document as it was, and the
//! builder can go on. The deprecated types are never written.

const std = @import("std");
const bson = @import("root.zig");
const read = @import("read.zig");
const check = @import("check.zig");
const codec = @import("encode.zig");
const Builder = @This();

allocator: std.mem.Allocator,
/// The document so far; the lengths of open documents are not filled in.
buffer: std.ArrayList(u8) = .empty,
/// The documents and arrays opened and not closed yet, the innermost
/// last; the top-level document is not among them.
levels: [bson.max_depth - 1]Level = undefined,
/// How many of `levels` are open.
open: usize = 0,

const Level = struct {
    /// Where the length of the document is in `buffer`.
    start: usize,
    /// In an array: the key of the next element.
    next_index: ?usize,
};

/// `error.InvalidBson`: the document would not be valid BSON, or a call
/// came out of turn, such as `end` with no document open.
pub const Error = bson.Error || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) Builder {
    return .{ .allocator = allocator };
}

/// Frees the document, unless `finish` has handed it over.
pub fn deinit(b: *Builder) void {
    b.buffer.deinit(b.allocator);
    b.* = undefined;
}

pub fn putDouble(b: *Builder, key: []const u8, value: f64) Error!void {
    return b.putValue(key, .{ .double = value });
}

pub fn putString(b: *Builder, key: []const u8, value: []const u8) Error!void {
    return b.putValue(key, .{ .string = value });
}

/// Copies a whole document in, after `RawDocument.validate`, and refuses
/// it if its levels and the open ones would exceed `bson.max_depth`.
pub fn putDocument(b: *Builder, key: []const u8, value: bson.RawDocument) Error!void {
    return b.putValue(key, .{ .document = value });
}

/// Like `putDocument`; the keys of the array are copied as they are.
pub fn putArray(b: *Builder, key: []const u8, value: bson.RawDocument) Error!void {
    return b.putValue(key, .{ .array = value });
}

pub fn putBinary(b: *Builder, key: []const u8, value: bson.Binary) Error!void {
    return b.putValue(key, .{ .binary = value });
}

pub fn putObjectId(b: *Builder, key: []const u8, value: bson.ObjectId) Error!void {
    return b.putValue(key, .{ .object_id = value });
}

pub fn putBoolean(b: *Builder, key: []const u8, value: bool) Error!void {
    return b.putValue(key, .{ .boolean = value });
}

pub fn putDateTime(b: *Builder, key: []const u8, value: bson.DateTime) Error!void {
    return b.putValue(key, .{ .date_time = value });
}

pub fn putNull(b: *Builder, key: []const u8) Error!void {
    return b.putValue(key, .null);
}

/// The options are written sorted, as the spec asks: "mi" becomes "im".
pub fn putRegex(b: *Builder, key: []const u8, value: bson.Regex) Error!void {
    return b.putValue(key, .{ .regex = value });
}

pub fn putJavaScript(b: *Builder, key: []const u8, code: []const u8) Error!void {
    return b.putValue(key, .{ .javascript = code });
}

pub fn putInt32(b: *Builder, key: []const u8, value: i32) Error!void {
    return b.putValue(key, .{ .int32 = value });
}

pub fn putTimestamp(b: *Builder, key: []const u8, value: bson.Timestamp) Error!void {
    return b.putValue(key, .{ .timestamp = value });
}

pub fn putInt64(b: *Builder, key: []const u8, value: i64) Error!void {
    return b.putValue(key, .{ .int64 = value });
}

pub fn putDecimal128(b: *Builder, key: []const u8, value: bson.Decimal128) Error!void {
    return b.putValue(key, .{ .decimal128 = value });
}

pub fn putMinKey(b: *Builder, key: []const u8) Error!void {
    return b.putValue(key, .min_key);
}

pub fn putMaxKey(b: *Builder, key: []const u8) Error!void {
    return b.putValue(key, .max_key);
}

/// Writes a value of any type but the deprecated ones (undefined,
/// DBPointer, symbol, JavaScript with scope), which give
/// `error.InvalidBson`.
pub fn putValue(b: *Builder, key: []const u8, value: bson.Value) Error!void {
    const mark = b.buffer.items.len;
    errdefer b.buffer.shrinkRetainingCapacity(mark);
    try b.header(std.meta.activeTag(value), key);
    switch (value) {
        .double => |d| try b.writeInt(u64, @bitCast(d)),
        .string, .javascript => |s| try b.writeString(s),
        .document, .array => |doc| {
            // The levels left: the top-level document and the open ones take theirs.
            try read.validate(doc.bytes, bson.max_depth - 1 - b.open);
            try b.writeBytes(doc.bytes);
        },
        .binary => |binary| {
            if (binary.subtype == .binary_old) {
                // The old subtype repeats the length inside its data.
                const len = try length(binary.bytes.len + 4);
                try b.writeInt(i32, len);
                try b.writeByte(@backingInt(binary.subtype));
                try b.writeInt(i32, len - 4);
            } else {
                try b.writeInt(i32, try length(binary.bytes.len));
                try b.writeByte(@backingInt(binary.subtype));
            }
            try b.writeBytes(binary.bytes);
        },
        .object_id => |id| try b.writeBytes(&id.bytes),
        .boolean => |v| try b.writeByte(@intFromBool(v)),
        .date_time => |t| try b.writeInt(i64, t.milliseconds),
        .null, .min_key, .max_key => {},
        .regex => |regex| {
            try b.writeCString(regex.pattern);
            const options = b.buffer.items.len;
            try b.writeCString(regex.options);
            std.mem.sort(u8, b.buffer.items[options .. b.buffer.items.len - 1], {}, std.sort.asc(u8));
        },
        .int32 => |n| try b.writeInt(i32, n),
        // The uint64 is little-endian: the increment comes first.
        .timestamp => |t| {
            try b.writeInt(u32, t.increment);
            try b.writeInt(u32, t.seconds);
        },
        .int64 => |n| try b.writeInt(i64, n),
        .decimal128 => |d| try b.writeBytes(&d.bytes),
        .undefined, .db_pointer, .symbol, .javascript_with_scope => return error.InvalidBson,
    }
    b.advance();
}

/// Writes `value` by its type, as `bson.encode` writes a field: a struct
/// as a document, a slice or an array as an array, an optional as null or
/// its value, a number, a string or a special type as the BSON value of
/// its own. A value that fails halfway, such as a document whose last
/// string is not UTF-8, leaves the document as it was.
pub fn put(b: *Builder, key: []const u8, value: anytype) Error!void {
    if (comptime check.value(@TypeOf(value), .encode)) |problem| @compileError("bson.Builder.put: " ++ problem);
    const mark = b.buffer.items.len;
    const open = b.open;
    const index = if (b.arrayIndex()) |i| i.* else 0;
    errdefer {
        b.buffer.shrinkRetainingCapacity(mark);
        b.open = open;
        if (b.arrayIndex()) |i| i.* = index;
    }
    try codec.writeElement(b, key, value, .{});
}

/// Opens a document under `key`; `end` closes it.
pub fn beginDocument(b: *Builder, key: []const u8) Error!void {
    return b.begin(.document, key);
}

/// Opens an array under `key`; `end` closes it.
pub fn beginArray(b: *Builder, key: []const u8) Error!void {
    return b.begin(.array, key);
}

/// Closes the document or array opened last.
pub fn end(b: *Builder) Error!void {
    if (b.open == 0) return error.InvalidBson;
    try b.close(b.levels[b.open - 1].start);
    b.open -= 1;
}

/// The document, which now belongs to the caller; the builder is empty
/// again. Every document and array opened must be closed first.
pub fn finish(b: *Builder) Error!bson.OwnedDocument {
    if (b.open != 0) return error.InvalidBson;
    try b.reserveLength();
    const mark = b.buffer.items.len;
    errdefer b.buffer.shrinkRetainingCapacity(mark);
    try b.close(0);
    const bytes = try b.buffer.toOwnedSlice(b.allocator);
    return .{ .bytes = bytes, .allocator = b.allocator };
}

fn begin(b: *Builder, kind: bson.Type, key: []const u8) Error!void {
    if (b.open == b.levels.len) return error.InvalidBson;
    const mark = b.buffer.items.len;
    errdefer b.buffer.shrinkRetainingCapacity(mark);
    try b.header(kind, key);
    const start = b.buffer.items.len;
    try b.writeBytes(&.{ 0, 0, 0, 0 });
    b.advance();
    b.levels[b.open] = .{ .start = start, .next_index = if (kind == .array) 0 else null };
    b.open += 1;
}

/// Writes the type and the key of the next element.
fn header(b: *Builder, kind: bson.Type, key: []const u8) Error!void {
    try b.reserveLength();
    try b.writeByte(@backingInt(kind));
    if (b.arrayIndex()) |index| {
        if (key.len != 0) return error.InvalidBson;
        var digits: [20]u8 = undefined;
        try b.writeCString(std.fmt.bufPrint(&digits, "{d}", .{index.*}) catch unreachable);
    } else try b.writeCString(key);
}

/// Moves the key of the open array, if any, past the element just written.
fn advance(b: *Builder) void {
    if (b.arrayIndex()) |index| index.* += 1;
}

/// The key of the next element, if the innermost open level is an array.
fn arrayIndex(b: *Builder) ?*usize {
    if (b.open == 0) return null;
    const level = &b.levels[b.open - 1];
    return if (level.next_index) |*index| index else null;
}

/// The top-level document's length goes first; it is filled in by `finish`.
fn reserveLength(b: *Builder) Error!void {
    if (b.buffer.items.len == 0) try b.writeBytes(&.{ 0, 0, 0, 0 });
}

/// Ends the document whose length is at `start`.
fn close(b: *Builder, start: usize) Error!void {
    const mark = b.buffer.items.len;
    errdefer b.buffer.shrinkRetainingCapacity(mark);
    try b.writeByte(0);
    const len = try length(b.buffer.items.len - start);
    std.mem.writeInt(i32, b.buffer.items[start..][0..4], len, .little);
}

fn writeByte(b: *Builder, value: u8) Error!void {
    try b.buffer.append(b.allocator, value);
}

fn writeBytes(b: *Builder, value: []const u8) Error!void {
    try b.buffer.appendSlice(b.allocator, value);
}

fn writeInt(b: *Builder, comptime T: type, value: T) Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try b.writeBytes(&buffer);
}

fn writeString(b: *Builder, value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidBson;
    try b.writeInt(i32, try length(value.len + 1));
    try b.writeBytes(value);
    try b.writeByte(0);
}

fn writeCString(b: *Builder, value: []const u8) Error!void {
    if (std.mem.findScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBson;
    try b.writeBytes(value);
    try b.writeByte(0);
}

/// A length as BSON writes it: an int32.
fn length(n: usize) bson.Error!i32 {
    return std.math.cast(i32, n) orelse error.InvalidBson;
}
