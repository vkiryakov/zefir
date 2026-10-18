//! zefir-mongo — MongoDB for zefir applications, written against `std.Io`
//! only: what every MongoDB driver of zefir shares. It imports no driver;
//! drivers import it.
//!
//! - `mongo.bson` — BSON, the format of MongoDB's documents and commands:
//!   read a document where it lies, check it, write one, turn structs and
//!   literals into documents and documents into structs, and print it as
//!   Extended JSON for logs and test messages.
//! - `mongo.Database` and `mongo.Collection` — the API of a database and
//!   its collections, the same on every driver: insert, update, replace,
//!   delete and `findOneAnd*`, with documents as raw BSON, built with
//!   `bson.Builder`, or written from structs and literals.
//! - `mongo.Client` and `mongo.Cursor` — the contract between zefir and a
//!   driver: a pointer and a table of functions, with the rules of the
//!   calls checked once, here, for every driver.
//! - `mongo.Error`, `mongo.outcome`, `mongo.Diagnostics` — what can go
//!   wrong in a call, whether the server may have run it, and the details
//!   for logs.
//! - The arguments and results of the driver's calls:
//!   `mongo.OperationContext`, `mongo.Command`, `mongo.WriteRequest`, their
//!   options, `mongo.WriteResult`, and `mongo.Capabilities` with the
//!   revision of the contract, `mongo.contract_revision`.
//! - `mongo.testing` — a scripted server, served on loopback or run in the
//!   process as a fake driver, for tests without MongoDB.

const std = @import("std");
const errors = @import("contract/errors.zig");
const requests = @import("contract/requests.zig");
const results = @import("contract/results.zig");
const capabilities = @import("contract/capabilities.zig");

pub const bson = @import("bson.zig");
pub const wire = @import("wire.zig");
pub const testing = @import("testing.zig");

pub const Database = @import("crud/Database.zig");
pub const Collection = @import("crud/Collection.zig");

pub const Client = @import("contract/Client.zig");
pub const Cursor = @import("contract/Cursor.zig");

pub const Error = errors.Error;
pub const Outcome = errors.Outcome;
pub const outcome = errors.outcome;
pub const Diagnostics = errors.Diagnostics;
pub const ServerError = errors.ServerError;
pub const Label = errors.Label;

pub const OperationContext = requests.OperationContext;
pub const Tracing = requests.Tracing;
pub const Command = requests.Command;
pub const CommandOptions = requests.CommandOptions;
pub const WriteKind = requests.WriteKind;
pub const WriteRequest = requests.WriteRequest;
pub const WriteOptions = requests.WriteOptions;
pub const CursorOptions = requests.CursorOptions;
pub const WriteResult = results.WriteResult;
pub const Upserted = results.Upserted;
pub const WriteError = results.WriteError;
pub const WriteConcernError = results.WriteConcernError;
pub const Capabilities = capabilities.Capabilities;
pub const ServerInfo = capabilities.ServerInfo;
pub const ServerKind = capabilities.ServerKind;
pub const contract_revision = capabilities.contract_revision;

test {
    std.testing.refAllDecls(@This());
    _ = bson;
    _ = wire;
    _ = testing;
    _ = @import("contract/errors_tests.zig");
    _ = @import("contract/types_tests.zig");
    _ = @import("contract/client_tests.zig");
    _ = @import("contract/signature.zig");
    _ = Collection;
    _ = @import("crud/document_tests.zig");
}
