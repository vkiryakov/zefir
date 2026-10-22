//! A generation of a connection: one client of the driver and its leases.
//! A connection has one current generation; a replacement makes a new one
//! and drains the old. Every generation is in one list of the registry
//! until it is freed, exactly once, by whoever brings it to "closed, and
//! no lease left".
//!
//! A lease keeps a generation's memory alive while its holder calls the
//! client out of the lock: a session, a cursor, or one call of `connect`,
//! `ping` or `connectionStats`. Leases change under the registry's lock,
//! and giving one back never does I/O.

const std = @import("std");
const Io = std.Io;
const driver = @import("../driver.zig");
const Registry = @import("../Registry.zig");
const Connection = @import("connection.zig").Connection;
const List = std.DoublyLinkedList;

/// The registry's mutex guards every field but `client` and `number`,
/// which do not change, and the events, which are atomic.
pub const Generation = struct {
    client: driver.Client,
    /// 1, 2, 3… for the generations of one connection.
    number: u64,
    state: State = .pending,
    leases: usize = 0,
    /// Null once its connection was removed.
    connection: ?*Connection,
    node: List.Node = .{},

    pub const State = enum {
        /// Opened, not connected yet: a registered, connecting or failed
        /// connection, or the new generation of a replacement in progress.
        pending,
        /// Connected and current: `tenant()` gives it out.
        active,
        /// Out of service, waiting for its leases.
        draining,
        /// Its client closed; the last lease frees it.
        closed,
    };

    pub fn of(node: *List.Node) *Generation {
        return @fieldParentPtr("node", node);
    }
};

/// A lease of `g`, under the registry's lock.
pub fn retain(g: *Generation) void {
    g.leases += 1;
}

/// A lease of `g` for a holder of another one, such as the cursor of a
/// session, even when `g` drains: the work of a session goes on where it
/// began. Takes the registry's lock.
pub fn acquire(r: *Registry, io: Io, g: *Generation) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    retain(g);
}

/// Gives a lease of `g` back, without I/O: the last one of a closed
/// generation frees it, after the lock.
pub fn release(r: *Registry, io: Io, g: *Generation) void {
    r.mutex.lockUncancelable(io);
    const free = drop(r, io, g);
    r.mutex.unlock(io);
    if (free) destroy(r, g);
}

/// `release` under the lock: true when the caller frees `g` with `destroy`
/// once it has let the lock go.
pub fn drop(r: *Registry, io: Io, g: *Generation) bool {
    _ = io;
    g.leases -= 1;
    return settle(r, g);
}

/// Under the lock: a closed generation without leases leaves the list,
/// and the caller frees it after the lock.
pub fn settle(r: *Registry, g: *Generation) bool {
    if (g.state != .closed or g.leases > 0) return false;
    r.generations.remove(&g.node);
    return true;
}

/// Frees `g`, out of the lock: `deinit` of a closed client is memory only.
pub fn destroy(r: *Registry, g: *Generation) void {
    g.client.deinit();
    r.gpa.destroy(g);
}
