//! `mongo.bson`: BSON, the binary format of MongoDB's documents and
//! commands (https://bsonspec.org/spec.html).

const std = @import("std");

/// The bytes are not a valid BSON document, or a document being written
/// would not be one.
pub const Error = error{InvalidBson};

/// How many documents and arrays may nest inside one another, the
/// top-level document included, as mongod allows.
pub const max_depth = 100;

test {
    std.testing.refAllDecls(@This());
}
