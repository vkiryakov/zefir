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
//!
//! Taking a generation out of service — for a replacement, a removal or
//! the shutdown — is `beginRetire` under the lock, then `finishRetire` in
//! the caller's task: it waits for the drain until a deadline, closes the
//! client out of the lock (one task does, the others wait for it), and
//! frees the generation when no lease is left; else the last lease frees
//! it.

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
    /// The tasks that take it out of service, each until it is done: like
    /// leases, they keep its memory, and so its events, alive.
    pins: usize = 0,
    /// Null once its connection was removed.
    connection: ?*Connection,
    /// A task took its close; the others wait for `closed`.
    closing: bool = false,
    /// The leases left when it was closed by force; null for a close after
    /// its drain.
    forced: ?usize = null,
    /// Set once it drains without leases, and at its close.
    drained: Io.Event = .unset,
    /// Set once its client is closed.
    closed: Io.Event = .unset,
    node: List.Node = .{},
    /// In one of the lists of a shutdown.
    shutdown_node: List.Node = .{},

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

    pub fn ofShutdown(node: *List.Node) *Generation {
        return @fieldParentPtr("shutdown_node", node);
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
/// once it has let the lock go. The last lease of a draining generation
/// wakes its drain.
pub fn drop(r: *Registry, io: Io, g: *Generation) bool {
    g.leases -= 1;
    if (g.leases == 0 and g.state == .draining) g.drained.set(io);
    // A shutdown waits for the last leases of generations closed before it.
    if (r.state != .running) r.cond.broadcast(io);
    return settle(r, g);
}

/// Under the lock: a closed generation without leases and pins leaves the
/// list, and the caller frees it after the lock.
pub fn settle(r: *Registry, g: *Generation) bool {
    if (g.state != .closed or g.leases > 0 or g.pins > 0) return false;
    r.generations.remove(&g.node);
    return true;
}

/// Frees `g`, out of the lock: `deinit` of a closed client is memory only.
pub fn destroy(r: *Registry, g: *Generation) void {
    g.client.deinit();
    r.gpa.destroy(g);
}

/// How a generation leaves service.
pub const Kind = enum {
    /// It may hold sessions: it drains until the deadline, and leases left
    /// then make its close forced.
    live,
    /// It never served sessions, being pending: it closes at once, never
    /// by force. A call in it, such as a connect, gets `Closed`.
    pending,
};

/// How a generation left service.
pub const Retired = struct {
    /// The leases left when it was closed by force, by this task or by the
    /// one that closed it; null for a close after its drain.
    forced: ?usize,
    /// This task closed it.
    closer: bool,
};

/// The first step of taking `g` out of service, under the lock: a pin for
/// the caller until its `finishRetire` is done, and a live generation
/// drains from now on.
pub fn beginRetire(io: Io, g: *Generation, kind: Kind) void {
    g.pins += 1;
    if (kind == .live and (g.state == .pending or g.state == .active)) {
        g.state = .draining;
        if (g.leases == 0) g.drained.set(io);
    }
}

/// The rest of taking `g` out of service, after `beginRetire`, without the
/// lock: waits until a live `g` drains or `until` passes on the .awake
/// clock, then closes its client, unless another task took the close, in
/// which case it waits for that one. A generation without leases is freed
/// on the way out; else its last lease frees it. The task's cancelation
/// waits until it returns.
pub fn finishRetire(r: *Registry, io: Io, g: *Generation, until: Io.Timestamp, kind: Kind) Retired {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (kind == .live) waitDrained(io, g, until);

    r.mutex.lockUncancelable(io);
    if (g.closing) {
        r.mutex.unlock(io);
        g.closed.waitUncancelable(io);
        r.mutex.lockUncancelable(io);
        const forced = g.forced;
        g.pins -= 1;
        const free = settle(r, g);
        r.mutex.unlock(io);
        if (free) destroy(r, g);
        return .{ .forced = forced, .closer = false };
    }
    g.closing = true;
    if (kind == .live and g.leases > 0) {
        g.forced = g.leases;
        r.forced += 1;
    }
    const forced = g.forced;
    r.mutex.unlock(io);

    // The driver cuts the calls in flight: their holders get Closed or
    // ConnectionLost, and give their leases back.
    g.client.close(io);

    r.mutex.lockUncancelable(io);
    g.state = .closed;
    if (g.connection) |c| {
        if (c.current == g) c.current = null;
    }
    g.drained.set(io);
    g.closed.set(io);
    g.pins -= 1;
    const free = settle(r, g);
    r.mutex.unlock(io);
    if (free) destroy(r, g);
    return .{ .forced = forced, .closer = true };
}

/// Until `g` drains or `until` passes on the .awake clock, in steps of an
/// hour at the most: a timer may fire early, and some `std.Io`
/// implementations overflow on a far one.
fn waitDrained(io: Io, g: *Generation, until: Io.Timestamp) void {
    while (!g.drained.isSet()) {
        const now = Io.Clock.awake.now(io);
        if (now.nanoseconds >= until.nanoseconds) return;
        const far = now.addDuration(.fromSeconds(3600));
        const end = if (until.nanoseconds < far.nanoseconds) until else far;
        // A timeout, or a wake for nothing: the loop looks again.
        g.drained.waitTimeout(io, .{ .deadline = end.withClock(.awake) }) catch {};
    }
}
