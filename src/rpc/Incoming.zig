//! One call that `rpc.transport.Dispatcher.admit` accepted. The engine
//! implements it. The transport fills the body, then calls exactly one of
//! `start` and `abandon`, and `cancel` when the client gives up.
//!
//! None of these functions returns `error.Canceled`, and none of them
//! swallows a cancelation request of the transport's task.

const std = @import("std");
const model = @import("model.zig");
const Reply = @import("Reply.zig");

const Incoming = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The engine's functions behind the interface: one constant table per
/// engine type.
pub const VTable = struct {
    body: *const fn (ptr: *anyopaque) []u8,
    start: *const fn (ptr: *anyopaque, io: std.Io, reply: Reply) ?model.Failure,
    abandon: *const fn (ptr: *anyopaque, io: std.Io) void,
    cancel: *const fn (ptr: *anyopaque, io: std.Io) void,
};

/// The buffer for the body, `body_len` bytes from `admit`. The transport
/// fills all of it before `start` and does not touch it after.
pub fn body(c: Incoming) []u8 {
    return c.vtable.body(c.ptr);
}

/// Hands the call to the engine, which schedules it and returns at once
/// with null. `reply.send` and `reply.release` may come from another task
/// before `start` returns. A `Failure` means the engine did not schedule
/// the call: no task for it, or the server is stopping (the grace of its
/// stop is over). The transport answers it like a refusal of `admit`, before
/// its `close` returns, and forgets it, and no `Reply` call follows. The engine has
/// freed the call by then, so no `cancel` of it may run after `start`
/// returns a `Failure`. The strings of the failure are static, literals of
/// the engine, as with `admit`: the transport may use them after the engine
/// has forgotten the call.
pub fn start(c: Incoming, io: std.Io, reply: Reply) ?model.Failure {
    return c.vtable.start(c.ptr, io, reply);
}

/// Gives up an accepted call that will not start, such as when the link
/// broke before the whole body came. The engine frees the call; nothing is
/// sent.
pub fn abandon(c: Incoming, io: std.Io) void {
    c.vtable.abandon(c.ptr, io);
}

/// The client gave up: a CANCEL frame came, or the connection of a direct
/// transport broke (NATS has no such signal). Allowed once `start` has
/// returned null, until `reply.release` returns, and every cancel must
/// return before `release` does: the engine frees the call then. So the
/// transport calls it under the lock that its `release` takes. A cancel
/// that comes while `start` runs waits until `start` returns, and is
/// dropped when `start` returned a `Failure` (the engine has freed the
/// call), as `rpc.testing.MemoryTransport` does. `cancel` cancels the call
/// and wakes its supervisor without locks: it never waits and never calls
/// `Reply`. A second call does nothing.
pub fn cancel(c: Incoming, io: std.Io) void {
    c.vtable.cancel(c.ptr, io);
}
