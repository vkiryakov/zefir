//! The `_id` of a document that an insert sends. By the CRUD spec an
//! insert MUST give a document without `_id` one, SHOULD put it first, and
//! reports the `_id` of every document, since the server does not:
//!
//! - a document with an `_id` of its own at the top level goes as it is,
//!   wherever the `_id` stands; an `_id` in a nested document is not its;
//! - a document without one gets an ObjectId from the database's
//!   generator as its first field. The caller's bytes do not change: a
//!   `RawDocument` or an `OwnedDocument` is copied with the new field
//!   before its own elements, and a struct is written with its `_id`
//!   first. An `_id` of null in a struct means "make one": BSON null is
//!   not written for it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bson = @import("mongo-bson");
const codec = bson.codec;
const results = @import("../results.zig");
const document = @import("document.zig");

/// `value`, a document of the three forms, as an insert sends it: as it
/// is when it has an `_id`, or with an ObjectId of `ids` first, in
/// `arena`. `error.InvalidBson`: the document is broken where it was read
/// to look for `_id`, or the codec cannot write the struct.
pub fn withId(arena: Allocator, io: Io, ids: *bson.ObjectId.Generator, value: anytype) bson.Builder.Error!bson.RawDocument {
    const T = @TypeOf(value);
    if (T == bson.RawDocument or T == bson.OwnedDocument) {
        const doc: bson.RawDocument = if (T == bson.OwnedDocument) value.raw() else value;
        if (try doc.get("_id") != null) return doc;
        return prepend(arena, doc, ids.next(io));
    }
    if (comptime @hasField(T, "_id")) {
        if (!isNull(@field(value, "_id"))) return document.encode(arena, value);
    }
    return writeWithId(arena, value, ids.next(io));
}

/// The `_id` of `doc`, a document as `withId` gives it, copied into
/// `allocator`; free it as `mongo.WriteResult.deinit` frees an `_id`.
pub fn idOf(allocator: Allocator, doc: bson.RawDocument) Allocator.Error!bson.Value {
    const value = (doc.get("_id") catch null) orelse return .null;
    return results.dupeValue(allocator, value);
}

fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        .null => true,
        else => false,
    };
}

/// The element `_id: <ObjectId>`: its type, its key and its 0, 12 bytes.
const id_len = 1 + 4 + 12;

/// `doc` with `_id: id` before its own elements, whose bytes are copied as
/// they are, of deprecated types too.
fn prepend(arena: Allocator, doc: bson.RawDocument, id: bson.ObjectId) bson.Builder.Error!bson.RawDocument {
    const len = std.math.cast(i32, doc.bytes.len + id_len) orelse return error.InvalidBson;
    const bytes = try arena.alloc(u8, @intCast(len));
    std.mem.writeInt(i32, bytes[0..4], len, .little);
    bytes[4] = @backingInt(bson.Type.object_id);
    bytes[5..9].* = "_id\x00".*;
    bytes[9..21].* = id.bytes;
    @memcpy(bytes[21..], doc.bytes[4..]);
    return .{ .bytes = bytes };
}

/// The struct `value` with `_id: id` first and its other fields after, as
/// `bson.encode` writes them; its own `_id` field, null, is left out.
fn writeWithId(arena: Allocator, value: anytype, id: bson.ObjectId) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(arena);
    try b.putObjectId("_id", id);
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "_id")) try codec.writeElement(&b, name, @field(value, name), .{});
    }
    return (try b.finish()).raw();
}
