//! zefir-mongo — MongoDB for zefir applications, written against `std.Io`
//! only: what every MongoDB driver of zefir shares. It imports no driver;
//! drivers import it.
//!
//! - `mongo.bson` — BSON, the format of MongoDB's documents and commands:
//!   read a document where it lies, check it, write one, turn structs and
//!   literals into documents and documents into structs, and print it as
//!   Extended JSON for logs and test messages.
//! - `mongo.Error`, `mongo.outcome`, `mongo.Diagnostics` — what can go
//!   wrong in a call, whether the server may have run it, and the details
//!   for logs.

const std = @import("std");
const errors = @import("contract/errors.zig");

pub const bson = @import("bson.zig");

pub const Error = errors.Error;
pub const Outcome = errors.Outcome;
pub const outcome = errors.outcome;
pub const Diagnostics = errors.Diagnostics;
pub const ServerError = errors.ServerError;
pub const Label = errors.Label;

test {
    std.testing.refAllDecls(@This());
    _ = bson;
    _ = @import("contract/errors_tests.zig");
}
