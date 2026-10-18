//! zefir-mongo — MongoDB for zefir applications, written against `std.Io`
//! only: what every MongoDB driver of zefir shares. It imports no driver;
//! drivers import it.
//!
//! - `mongo.bson` — BSON, the format of MongoDB's documents and commands:
//!   read a document where it lies, check it, write one, turn structs and
//!   literals into documents and documents into structs, and print it as
//!   Extended JSON for logs and test messages.

const std = @import("std");

pub const bson = @import("bson.zig");

test {
    std.testing.refAllDecls(@This());
    _ = bson;
}
