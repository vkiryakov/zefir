//! zefir-mongo — an async driver of MongoDB for zefir applications,
//! written against `std.Io` only. It talks to one standalone mongod of
//! MongoDB 7.0 or later, over plain TCP: there is no TLS, so it belongs on
//! a trusted network only.
//!
//! - `mongo.Client` and `mongo.Cursor` — the client: `init`, `connect`,
//!   `close` and `deinit`, and the calls `runCommand`, `openCursor` and
//!   `write`, with SCRAM and a pool of connections. Its options are
//!   `mongo.Client.Options`, what `stats` returns `mongo.Client.Stats`.
//! - `mongo.Database` and `mongo.Collection` — the API of a database and
//!   its collections over the client: insert, update, replace, delete,
//!   find and `findOneAnd*`, aggregate, count and distinct, indexes,
//!   collections and any command, with documents as raw BSON, built with
//!   `bson.Builder`, or written from structs and literals.
//! - `mongo.WriteConcern` — when the server acknowledges a write: the
//!   `write_concern` of the options of the writes and of `findOneAnd*`.
//! - `mongo.Error`, `mongo.outcome`, `mongo.Diagnostics` — what can go
//!   wrong in a call, whether the server may have run it, and the details
//!   for logs.
//! - The arguments and results of the client's calls:
//!   `mongo.OperationContext`, `mongo.Command`, `mongo.WriteRequest`, their
//!   options and `mongo.WriteResult`.
//! - `mongo.OdmDriver` — the reference driver of zefir-odm: zefir-mongo
//!   under odm's driver contract, whose `driver()` goes to
//!   `odm.Registry.init`.
//! - `mongo.SchedulerStore` — the store of zefir-scheduler in MongoDB, for
//!   a service of several instances: zefir-mongo under scheduler's store
//!   contract, whose `store()` goes to `scheduler.Client` and
//!   `scheduler.Worker`.
//! - `mongo.testing` — a scripted server on loopback, for tests of code on
//!   zefir-mongo without MongoDB: the client connects to it as to a
//!   mongod.
//!
//! The documents and commands are the BSON of zefir-mongo-bson,
//! `@import("mongo-bson")`: `bson.Builder`, `bson.encode`, `bson.decode`
//! and the rest.

const std = @import("std");
const errors = @import("errors.zig");
const requests = @import("requests.zig");
const results = @import("results.zig");

pub const testing = @import("testing.zig");
/// The wire protocol, for the client and `testing.FakeServer` only.
const wire = @import("wire.zig");

pub const Client = @import("Client.zig");
pub const Cursor = @import("Cursor.zig");

pub const Database = @import("crud/Database.zig");
pub const Collection = @import("crud/Collection.zig");
pub const WriteConcern = @import("crud/options.zig").WriteConcern;

/// zefir-mongo under the driver contract of zefir-odm.
pub const OdmDriver = @import("OdmDriver.zig");
/// zefir-mongo under the store contract of zefir-scheduler.
pub const SchedulerStore = @import("SchedulerStore.zig");

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

test {
    std.testing.refAllDecls(@This());
    _ = wire;
    _ = testing;
    _ = @import("errors_tests.zig");
    _ = @import("types_tests.zig");
    _ = Collection;
    _ = @import("crud/document_tests.zig");
    _ = @import("crud/id_tests.zig");
    _ = @import("crud/insert_tests.zig");
    _ = @import("crud/update_tests.zig");
    _ = @import("crud/find_and_modify_tests.zig");
    _ = @import("crud/find_tests.zig");
    _ = @import("crud/aggregate_tests.zig");
    _ = @import("crud/index.zig");
    _ = @import("crud/index_tests.zig");
    _ = @import("crud/database_tests.zig");
    _ = @import("crud/forms_tests.zig");
    _ = @import("crud/write_errors_tests.zig");
    _ = @import("crud/write_concern_tests.zig");
    _ = @import("uri.zig");
    _ = @import("uri_tests.zig");
    _ = @import("OwnedOptions.zig");
    _ = @import("engine/time.zig");
    _ = @import("engine/race.zig");
    _ = @import("engine/DeadlineStream.zig");
    _ = @import("engine/Connection.zig");
    _ = @import("engine/connect.zig");
    _ = @import("engine/handshake.zig");
    _ = @import("engine/scram.zig");
    _ = @import("engine/KeyCache.zig");
    _ = @import("engine/Pool.zig");
    _ = @import("engine/errors.zig");
    _ = @import("engine/command.zig");
    _ = @import("engine/cursor.zig");
    _ = @import("engine/write.zig");
    _ = @import("tests/connection_tests.zig");
    _ = @import("tests/handshake_tests.zig");
    _ = @import("tests/auth_tests.zig");
    _ = @import("tests/pool_tests.zig");
    _ = @import("tests/lifecycle_tests.zig");
    _ = @import("tests/command_tests.zig");
    _ = @import("tests/errors_tests.zig");
    _ = @import("tests/cursor_tests.zig");
    _ = @import("tests/write_tests.zig");
    _ = @import("tests/rules_tests.zig");
    _ = @import("tests/odm_driver_tests.zig");
    _ = @import("tests/odm_conformance.zig");
    _ = SchedulerStore;
    _ = @import("tests/scheduler_store_tests.zig");
    _ = @import("tests/scheduler_records_tests.zig");
    _ = @import("tests/scheduler_claims_tests.zig");
    _ = @import("tests/scheduler_errors_tests.zig");
}
