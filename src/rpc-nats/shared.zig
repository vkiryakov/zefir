//! What the server side and the client side of the NATS transport share.
//! Internal to the module.

const std = @import("std");
const core = @import("core");
const Transport = @import("Transport.zig");

/// A counter of `Transport.Counters`, by its name.
pub const Counter = std.meta.FieldEnum(Transport.Counters);

/// One more of `counter`.
pub fn count(t: *Transport, counter: Counter) void {
    _ = t.counts.getPtr(counter).fetchAdd(1, .monotonic);
}

/// In Debug, panics when `io` is another `std.Io` than the transport's
/// first one: canceling a task would not end a wait inside the library.
pub fn checkIo(t: *Transport, io: std.Io) void {
    if (!std.debug.runtime_safety) return;
    const first = t.io_vtable.cmpxchgStrong(null, io.vtable, .acq_rel, .acquire) orelse return;
    if (first != io.vtable) @panic("rpc_nats.Transport: called with another std.Io than before; pass the one the NATS connection runs on");
}

/// A timeout that ends `duration` from now; saturates.
pub fn timeoutAfter(io: std.Io, duration: std.Io.Duration) std.Io.Timeout {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), duration);
    return deadline.toTimeout();
}

/// How often a side that waits for `Transport.confirming` looks again: the
/// other side holds it for a flush, one round trip to the broker.
const confirm_poll: std.Io.Duration = .fromMilliseconds(1);

/// Takes `t.confirming`, waiting no longer than `deadline`.
pub fn lockConfirming(t: *Transport, io: std.Io, deadline: core.Deadline) error{ Timeout, Canceled }!void {
    while (!t.confirming.tryLock()) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.Timeout;
        try io.sleep(confirm_poll, .awake);
    }
}
