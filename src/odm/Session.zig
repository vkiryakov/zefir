//! `odm.Session`: a tenant's database, for one task at a time.
//!
//! ```zig
//! var acme = try registry.tenant(io, tenant_id);
//! defer acme.deinit(io);
//! const users = acme.collection(User);
//! ```
//!
//! `registry.tenant(io, id)` gives a session with a lease of the generation
//! of the tenant's connection that is current then, and a copy of the name
//! of the tenant's database. Its work goes on there until its `deinit`,
//! even when the connection is replaced or the tenant is provisioned anew
//! or removed meanwhile: the sessions taken after that get the new ones.
//! After a forced close of its generation — a drain that ran out, or a
//! shutdown past its deadline — its calls get `Closed`. `deinit` gives the
//! lease back and never does I/O.
//!
//! One task at a time calls through a session: its diagnostics are those
//! of its latest call. For work in parallel within one tenant, take a
//! session for each task. In safe builds a session that two tasks call
//! through at once panics, and so does a collection used after the
//! session's `deinit`. A session is a value of the caller, and it has to
//! stay where it is while its collections are in use.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const leases = @import("registry/generation.zig");
const operations = @import("Collection.zig");
const Registry = @import("Registry.zig");
const Diagnostics = errors.Diagnostics;
const Collection = operations.Collection;

const Session = @This();

// The fields are for odm's collections and cursors; the application uses
// the methods.

registry: *Registry,
/// The generation whose lease the session holds.
generation: *leases.Generation,
/// The database of the tenant: the first `name_len` bytes.
name_buf: [64]u8,
name_len: u8,
/// The details of the latest error of a call through the session.
diag: Diagnostics = .{},
/// In safe builds: a call through the session is in progress. Atomic,
/// since the mistake it catches is two tasks at once.
busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},
/// In safe builds: `deinit` came.
released: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},

/// The collection of the model `T` in the tenant's database. The checks
/// of the model run at compile time. It is valid until the session's
/// `deinit`.
pub fn collection(s: *Session, comptime T: type) Collection(T) {
    return .{ .session = s };
}

/// The name of the tenant's database.
pub fn database(s: *const Session) []const u8 {
    return s.name_buf[0..s.name_len];
}

/// The details of the latest error of a call through this session: the
/// server's code, the item of a write, the rule or the path, and a text.
pub fn diagnostics(s: *const Session) *const Diagnostics {
    return &s.diag;
}

/// Gives the lease back, without I/O; the collections of the session are
/// no longer valid. Its cursors keep leases of their own and live on.
pub fn deinit(s: *Session, io: Io) void {
    s.registry.checkUse(io);
    if (std.debug.runtime_safety) {
        if (s.released) @panic("zefir-odm: Session.deinit() twice: deinit a session once");
        if (s.busy.load(.acquire)) @panic("zefir-odm: a session used by two tasks at once: take a session for each task");
        s.released = true;
    }
    leases.release(s.registry, io, s.generation);
}
