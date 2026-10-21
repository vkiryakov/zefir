//! A BSON document where it lies: borrowed bytes, read lazily.
//!
//! `init` checks only the length at the front and the 0 at the end. The
//! iterator and the lookups check each element when they reach it, so a
//! broken element gives `error.InvalidBson` there; `validate` checks the
//! whole document, the documents in it included, at once. Check bytes
//! from the network with `validate` before you hand them on.
//!
//! The document lives as long as its bytes, and so do the strings and
//! documents read from it.
//!
//! ```zig
//! const reply = try bson.RawDocument.init(bytes);
//! try reply.validate();
//! const ok = try (try reply.get("ok")).?.asF64();
//! const id = (try reply.getPath("cursor.id")).?;
//! ```

const std = @import("std");
const bson = @import("root.zig");
const read = @import("read.zig");
const ejson = @import("ejson.zig");
const RawDocument = @This();

/// The whole document: the int32 length, the elements and the final 0.
bytes: []const u8,

/// {}
pub const empty: RawDocument = .{ .bytes = &.{ 5, 0, 0, 0, 0 } };

/// The document in `bytes`, which must be exactly one document: its
/// length is `bytes.len` and its last byte is 0. The elements are not
/// checked here; see `validate`.
pub fn init(bytes: []const u8) bson.Error!RawDocument {
    if (!read.isDocument(bytes)) return error.InvalidBson;
    return .{ .bytes = bytes };
}

/// Checks every element, of this document and of every document and
/// array in it, and that at most `bson.max_depth` of them nest inside one
/// another, this one included.
pub fn validate(doc: RawDocument) bson.Error!void {
    return read.validate(doc.bytes, bson.max_depth);
}

/// The elements in their order. Each call of `next` checks one element.
pub fn iterator(doc: RawDocument) Iterator {
    return .{ .bytes = doc.bytes };
}

pub const Iterator = struct {
    bytes: []const u8,
    /// Where the next element begins.
    pos: usize = 4,

    /// The next element, or null after the last. A broken element gives
    /// `error.InvalidBson`, at this call and at every later one.
    pub fn next(it: *Iterator) bson.Error!?bson.Element {
        if (it.bytes.len < 5) return error.InvalidBson;
        const end = it.bytes.len - 1;
        if (it.pos >= end) return null;
        const element, const after = try read.element(it.bytes, it.pos, end);
        it.pos = after;
        return element;
    }
};

/// The value of the first element with this key, or null if there is
/// none. Elements are checked up to the one found.
pub fn get(doc: RawDocument, key: []const u8) bson.Error!?bson.Value {
    var it = doc.iterator();
    while (try it.next()) |element| {
        if (std.mem.eql(u8, element.key, key)) return element.value;
    }
    return null;
}

/// The value at a path of keys joined by dots, through documents and
/// arrays: "cursor.id", "cursor.firstBatch.0". Null if any key is missing
/// or a value on the way is neither a document nor an array. A key that
/// holds a dot itself is reached with `get` only.
pub fn getPath(doc: RawDocument, path: []const u8) bson.Error!?bson.Value {
    var current = doc;
    var rest = path;
    while (true) {
        const dot = std.mem.findScalar(u8, rest, '.');
        const found = (try current.get(rest[0 .. dot orelse rest.len])) orelse return null;
        const at = dot orelse return found;
        current = switch (found) {
            .document, .array => |inner| inner,
            else => return null,
        };
        rest = rest[at + 1 ..];
    }
}

/// The first element: in a command, its name.
pub fn first(doc: RawDocument) bson.Error!?bson.Element {
    var it = doc.iterator();
    return it.next();
}

/// A copy of the document in `allocator`.
pub fn dupe(doc: RawDocument, allocator: std.mem.Allocator) std.mem.Allocator.Error!bson.OwnedDocument {
    return .{ .bytes = try allocator.dupe(u8, doc.bytes), .allocator = allocator };
}

/// Prints the document as Relaxed Extended JSON, for logs and test
/// messages: `{f}`. A document that fails `validate` prints as
/// "<invalid BSON>". Values of documents print as they are, so keep
/// secrets out of what you log.
pub fn format(doc: RawDocument, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return ejson.writeDocument(w, doc);
}
