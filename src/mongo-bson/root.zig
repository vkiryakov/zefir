//! zefir-mongo-bson — BSON, the binary format of MongoDB's documents and
//! commands (https://bsonspec.org/spec.html). Import it as
//! `@import("mongo-bson")`, or reach it as `@import("zefir").mongo_bson`.
//! zefir-mongo reads and writes its documents and commands with it, and so
//! can any other driver: the module imports nothing but std.
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
//! - `codec` — the parts of the codec for code that builds on it, such as
//!   zefir-mongo: the check of a type, the writing of one element or of
//!   the fields of a struct, the checks of a document's frame and depth.
//! - `testing.vectors` — the BSON test vectors of zefir: a document of each
//!   BSON type with what it reads back as, and bytes no reader may accept.
//!
//! No bytes make a reader go out of bounds or panic: broken ones give
//! `error.InvalidBson`.
//!
//! ```zig
//! const User = struct { name: []const u8, age: i32 };
//! const doc = try bson.encode(gpa, User{ .name = "Ann", .age = 30 }, .{});
//! defer doc.deinit();
//! const user = try bson.decode(User, arena, doc.raw(), .{});
//! const by_age = bson.literal(.{ .age = -1 }); // static bytes, no allocator
//! ```

const std = @import("std");
const value = @import("value.zig");
const types = @import("types.zig");
const encoding = @import("encode.zig");
const decoding = @import("decode.zig");

pub const RawDocument = @import("RawDocument.zig");
pub const OwnedDocument = @import("OwnedDocument.zig");
pub const Builder = @import("Builder.zig");
pub const encode = encoding.encode;
pub const EncodeOptions = encoding.EncodeOptions;
pub const literal = @import("literal.zig").literal;
pub const decode = decoding.decode;
pub const DecodeOptions = decoding.DecodeOptions;
pub const DecodeError = decoding.DecodeError;
pub const DecodeDiagnostics = decoding.DecodeDiagnostics;
pub const Value = value.Value;
pub const Element = value.Element;
pub const Type = value.Type;
pub const NumberError = value.NumberError;
pub const ObjectId = @import("ObjectId.zig");
pub const DateTime = types.DateTime;
pub const Timestamp = types.Timestamp;
pub const Binary = types.Binary;
pub const Decimal128 = @import("Decimal128.zig");
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

/// The parts of the codec for code that builds on it.
pub const codec = @import("codec.zig");

/// What tests of code on BSON need.
pub const testing = struct {
    pub const vectors = @import("vectors.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(codec);
    std.testing.refAllDecls(codec.check);
    std.testing.refAllDecls(testing);
    _ = @import("read.zig");
    _ = @import("read_tests.zig");
    _ = @import("builder_tests.zig");
    _ = @import("types_tests.zig");
    _ = @import("ejson_tests.zig");
    _ = @import("fuzz.zig");
    _ = @import("encode_tests.zig");
    _ = @import("literal_tests.zig");
    _ = @import("decode_tests.zig");
    _ = @import("check_tests.zig");
}
