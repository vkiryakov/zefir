//! `mongo.bson`: BSON, the binary format of MongoDB's documents and
//! commands (https://bsonspec.org/spec.html).
//!
//! - `RawDocument` — a document where it lies, in borrowed bytes: read
//!   element by element, looked up by key or path, checked as a whole,
//!   printed with `{f}` as Relaxed Extended JSON.
//! - `OwnedDocument` — a document whose bytes belong to an allocator, such
//!   as a copy made with `RawDocument.dupe`.
//! - `Builder` — writes a document, element by element.
//! - `encode` — writes a struct as a document, by the types of its fields;
//!   `Builder.put` writes one value so.
//! - `literal` — writes a document known at compile time, such as a sort,
//!   into static bytes.
//! - `decode` — reads a document into a struct, by the types of its fields.
//! - `Value` — the value of one element, of any BSON type; its strings and
//!   documents are slices into the document.
//! - The types Zig has no type for: `ObjectId` with its `Generator`,
//!   `DateTime`, `Timestamp`, `Binary`, `Decimal128`, `Regex`, `Null`,
//!   `MinKey`, `MaxKey`, and the deprecated `DbPointer` and
//!   `JavaScriptWithScope`, which are read but never written.
//!
//! No bytes make a reader go out of bounds or panic: broken ones give
//! `error.InvalidBson`.

const std = @import("std");
const value = @import("bson/value.zig");
const types = @import("bson/types.zig");
const encoding = @import("bson/encode.zig");
const decoding = @import("bson/decode.zig");

pub const encode = encoding.encode;
pub const EncodeOptions = encoding.EncodeOptions;
pub const literal = @import("bson/literal.zig").literal;
pub const decode = decoding.decode;
pub const DecodeOptions = decoding.DecodeOptions;
pub const DecodeError = decoding.DecodeError;
pub const DecodeDiagnostics = decoding.DecodeDiagnostics;
pub const RawDocument = @import("bson/RawDocument.zig");
pub const OwnedDocument = @import("bson/OwnedDocument.zig");
pub const Builder = @import("bson/Builder.zig");
pub const Value = value.Value;
pub const Element = value.Element;
pub const Type = value.Type;
pub const NumberError = value.NumberError;
pub const ObjectId = @import("bson/ObjectId.zig");
pub const DateTime = types.DateTime;
pub const Timestamp = types.Timestamp;
pub const Binary = types.Binary;
pub const Decimal128 = @import("bson/Decimal128.zig");
pub const Regex = types.Regex;
pub const Null = types.Null;
pub const MinKey = types.MinKey;
pub const MaxKey = types.MaxKey;
pub const DbPointer = types.DbPointer;
pub const JavaScriptWithScope = types.JavaScriptWithScope;

/// The bytes are not a valid BSON document, or a document being written
/// would not be one.
pub const Error = error{InvalidBson};

/// How many documents and arrays may nest inside one another, the
/// top-level document included, as mongod allows.
pub const max_depth = 100;

test {
    std.testing.refAllDecls(@This());
    _ = @import("bson/read.zig");
    _ = @import("bson/read_tests.zig");
    _ = @import("bson/builder_tests.zig");
    _ = @import("bson/types_tests.zig");
    _ = @import("bson/ejson_tests.zig");
    _ = @import("bson/fuzz.zig");
    _ = @import("bson/encode_tests.zig");
    _ = @import("bson/literal_tests.zig");
    _ = @import("bson/decode_tests.zig");
}
