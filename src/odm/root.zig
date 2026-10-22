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

test {
    std.testing.refAllDecls(@This());
}
