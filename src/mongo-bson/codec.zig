//! `bson.codec`: the parts of the codec for code that builds on it, such as
//! the collection API and the wire protocol of zefir-mongo. They follow the
//! rules of `bson.encode` and `bson.decode`.

const checking = @import("check.zig");
const encoding = @import("encode.zig");
const reading = @import("read.zig");

/// The comptime check of the types that the codec takes, which names the
/// first field that does not fit and says what to write instead.
pub const check = struct {
    /// Why `T` cannot be the document that `encode` writes or `decode`
    /// fills, as the end of a compile error, or null when it can.
    pub const document = checking.document;
    /// Why a value of type `T` cannot be written into a document, or read
    /// from one, or null.
    pub const value = checking.value;
    /// Whether the codec writes `T` as a BSON value of its own: the
    /// documents and values of zefir-mongo-bson and its special types.
    pub const isSpecial = checking.isSpecial;
    /// Which way the codec goes: `.encode` or `.decode`.
    pub const Direction = checking.Direction;
};

/// Writes a value under a key into the document open in a `Builder`, as
/// `encode` writes a field; in an array the key is "".
pub const writeElement = encoding.writeElement;
/// Writes the fields of a struct into the document open in a `Builder`.
pub const writeFields = encoding.writeFields;
/// How the codec writes a value of a type: one BSON value, a document, an
/// array of a tuple's or of a list's items, or null or the value.
pub const Shape = encoding.Shape;
pub const shape = encoding.shape;

/// Whether bytes are framed as one document: the length at the front is
/// their number, and the last byte is 0. The elements are not checked.
pub const isDocument = reading.isDocument;
/// Checks every element of the document `bytes` and of the documents in
/// it, with at most `levels` (and at most `max_levels`) documents inside
/// one another, `bytes` included.
pub const validateDepth = reading.validate;
/// The most levels `validateDepth` walks: a stored document of
/// `bson.max_depth` levels inside the three levels of a reply,
/// `reply.cursor.firstBatch`.
pub const max_levels = reading.max_levels;
