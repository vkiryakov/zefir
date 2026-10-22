//! zefir-odm — a typed ODM for MongoDB. Its import name is `odm`, and in
//! the umbrella module it is `zefir.odm`.
//!
//! A model is a plain Zig struct: its schema (`odm_schema`) and the rules
//! of zefir-validator (`field_rules`) are declarations in it. Filters,
//! updates and sorts are anonymous literals, which the compiler checks
//! against the model. odm reaches a database only through the driver
//! contract: `odm.Driver` opens a client, `odm.Client` runs CRUD
//! operations on BSON, `odm.RawCursor` hands out documents. zefir-mongo
//! holds the reference driver, `mongo.OdmDriver`; a driver is "zefir
//! compatible" when it passes `odm.testing.conformance`. `odm.Registry`
//! keeps connections (a server and a login: one client of the driver, with
//! its pool) and tenants (a connection and a database), hands out sessions
//! that lease a generation of a connection, replaces connections on the
//! fly and closes the old ones without tasks of its own. The BSON is that
//! of zefir-mongo-bson.
//!
//! How a service uses it:
//!
//! 1. Start: `mongo.OdmDriver.init(gpa)`, `odm.Registry.init(gpa, io,
//!    driver.driver(), .{})`, then `registerConnection` (no network) and
//!    `connect` (the network and the login).
//! 2. A new tenant: the service hears of it (over NATS, rpc or anything
//!    else) and calls `provisionTenant` with a version; the registry makes
//!    or reuses a connection, checks that it works and publishes the
//!    tenant at once, whole.
//! 3. A query: `registry.tenant(io, id)` gives a `Session` that holds a
//!    lease, `session.collection(User)` a typed collection; its operation
//!    becomes BSON and goes through the driver to mongod.
//! 4. New credentials: a second user on the server, `replaceConnection`
//!    with its uri and password, which opens a new generation, publishes
//!    it, waits until the leases of the old one come back and closes it in
//!    the caller's task; then the first user goes. No call fails on the
//!    way, and the same event again changes nothing.
//! 5. Shutdown: `shutdown(io, deadline)` closes everything by the
//!    deadline, then `deinit(io)` frees it.

const std = @import("std");
const errors = @import("errors.zig");
const driver = @import("driver.zig");
const schema = @import("model/schema.zig");

/// The errors that a driver returns, each in its class of `outcome`.
pub const DriverError = errors.DriverError;
/// The errors of odm's calls: `DriverError` and odm's own.
pub const Error = errors.Error;
/// What `Registry.shutdown` returns when the deadline comes first.
pub const ShutdownError = errors.ShutdownError;
pub const Outcome = errors.Outcome;
pub const outcome = errors.outcome;
pub const Diagnostics = errors.Diagnostics;

/// The settings of one connection: a server and a login.
pub const ConnectionConfig = driver.ConnectionConfig;
/// The operations of a client beyond those every driver has.
pub const Capabilities = driver.Capabilities;
/// A driver: opens clients by their settings.
pub const Driver = driver.Driver;
/// A client of a driver: one server and login, with its pool.
pub const Client = driver.Client;
/// The documents of a find or an aggregate, from a driver.
pub const RawCursor = driver.RawCursor;

/// The schema of a model, which the model declares in itself:
/// `pub const odm_schema: odm.Schema(User) = .{ .collection = "users", .id = .id };`.
pub const Schema = schema.Schema;
/// The BSON keys of a model's top-level fields: a `?[]const u8 = null` for
/// each field.
pub const Names = schema.Names;
/// An index of a model's collection, which `ensureIndexes` creates.
pub const Index = schema.Index;
/// One key of an index: a path of the model and its order,
/// `.{ .email = .asc }`, `.{ .@"profile.city" = .desc }`.
pub const IndexKey = schema.IndexKey;
pub const IndexOrder = schema.IndexOrder;
/// The paths of a model's fields, by their Zig names joined by '.'.
pub const Path = schema.Path;
/// What an insert takes: the model itself, or the model without its id
/// when the id is a `bson.ObjectId` that odm always makes.
pub const Insert = schema.Insert;
/// The type of a model's id, without the optional.
pub const Id = schema.Id;

/// Every check of a model at compile time: its schema, the types of its
/// fields and its `field_rules`. Zig compiles only code that is used, so a
/// package that declares models has them checked in a test:
/// `test { comptime odm.assertModel(User); }`. Does nothing at run time.
pub fn assertModel(comptime T: type) void {
    comptime schema.check(T);
}

/// What tests of odm and of the code over it need: `testing.FakeDriver`.
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("signature.zig");
    _ = @import("tests/errors_tests.zig");
    _ = @import("tests/driver_tests.zig");
    _ = @import("tests/fake_driver_tests.zig");
    _ = @import("tests/model_tests.zig");
}
