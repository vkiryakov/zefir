//! How the engine answers one call that a server transport delivered, and
//! tells the transport when to forget the call. The transport implements
//! it, one per call: a type with the methods `send` and `release`, passed
//! as `rpc.transport.Reply.init(&call)` to `rpc.transport.Incoming.start`.
//!
//! The engine calls `send` at most once and `release` exactly once, last.
//! The handler runs in another task, so both may come before `start` has
//! returned: the transport records the call in its tables before `start`,
//! and holds no lock across `start` or `abandon` that `send` or `release`
//! takes (`std.Io.Mutex` is not reentrant). The engine never calls `Reply`
//! from inside `admit`, `start`, `abandon` or `cancel`.

const std = @import("std");
const model = @import("model.zig");
const signature = @import("signature.zig");

const Reply = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The transport's functions behind the interface: one constant table per
/// reply type, built by `init`. Entries added later come with defaults.
pub const VTable = struct {
    send: *const fn (ptr: *anyopaque, io: std.Io, response: *const model.Response) SendError!void,
    release: *const fn (ptr: *anyopaque, io: std.Io, disposition: Disposition) void,
};

/// `Closed`: the link is gone and the response with it; the engine counts
/// it. `ResponseTooLarge`: the response does not fit the transport; the
/// engine may send a small `resource_exhausted` failure instead.
pub const SendError = error{ Closed, ResponseTooLarge, OutOfMemory, Unexpected } || std.Io.Cancelable;

/// How a call ended, for brokers that acknowledge messages (AMQP: ack, or
/// nack and requeue). Later releases may add values, so a `switch` over it
/// needs an `else` branch.
pub const Disposition = enum(u8) {
    /// The handler ran; its response was sent, or sending was tried.
    completed,
    /// The handler never started: it was taken off the queue at shutdown,
    /// or the stop, the deadline or the client ended the call before its
    /// handler ran. Running the call on another replica is safe.
    not_started,
    /// The handler started and was canceled: whether it did its work is
    /// unknown.
    canceled,
    _,
};

/// Sends the response of the call. At most once, except that after
/// `ResponseTooLarge` the engine may send a small failure. `response` is
/// borrowed until `send` returns. It may wait for room to send, as a
/// cancelation point.
pub fn send(r: Reply, io: std.Io, response: *const model.Response) SendError!void {
    return r.vtable.send(r.ptr, io, response);
}

/// The call is over: exactly once and last, after the handler has really
/// ended, so the slot of the call stays taken until then. The transport
/// removes the call from its tables here; once `release` returns, it calls
/// `Incoming.cancel` of this call no more. With no `error.Canceled` to
/// return, `release` must not swallow a cancelation request of the calling
/// task: it locks with `lockUncancelable`, works under
/// `io.swapCancelProtection(.blocked)`, or calls `io.recancel()` after a
/// cancelation point returned `error.Canceled`.
pub fn release(r: Reply, io: std.Io, disposition: Disposition) void {
    r.vtable.release(r.ptr, io, disposition);
}

const interface = "rpc.transport.Reply";

/// The interface of `impl: *T`, where `T` has the methods `send` and
/// `release`: the functions of `VTable` with `self: *T` in place of
/// `*anyopaque`. A missing method or another signature stops the build
/// with a message that names the method and the signature to write.
pub fn init(impl: anytype) Reply {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "reply", Ptr);
    comptime signature.expectMethod(interface, T, "send", fn (Ptr, std.Io, *const model.Response) SendError!void, "pub fn send(self: *@This(), io: std.Io, response: *const rpc.Response) rpc.transport.Reply.SendError!void");
    comptime signature.expectMethod(interface, T, "release", fn (Ptr, std.Io, Disposition) void, "pub fn release(self: *@This(), io: std.Io, disposition: rpc.transport.Reply.Disposition) void");
    const gen = struct {
        fn sendFn(ptr: *anyopaque, io: std.Io, response: *const model.Response) SendError!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.send(self, io, response);
        }
        fn releaseFn(ptr: *anyopaque, io: std.Io, disposition: Disposition) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.release(self, io, disposition);
        }
        const vtable: VTable = .{ .send = sendFn, .release = releaseFn };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}

/// A fake reply that records what the engine did.
const Recorder = struct {
    sent: u32 = 0,
    body: []const u8 = "",
    released: ?Disposition = null,

    pub fn send(self: *Recorder, io: std.Io, response: *const model.Response) SendError!void {
        _ = io;
        self.sent += 1;
        self.body = response.body;
    }

    pub fn release(self: *Recorder, io: std.Io, disposition: Disposition) void {
        _ = io;
        self.released = disposition;
    }
};

test "init builds a reply whose calls reach the methods" {
    const io = std.testing.io;
    var recorder: Recorder = .{};
    const reply: Reply = .init(&recorder);
    try reply.send(io, &.{ .status = .ok, .body = "{}" });
    try std.testing.expectEqual(@as(u32, 1), recorder.sent);
    try std.testing.expectEqualStrings("{}", recorder.body);

    // A copy is the same reply: two pointers, nothing else.
    const copy = reply;
    copy.release(io, .not_started);
    try std.testing.expectEqual(Disposition.not_started, recorder.released.?);
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(Reply));
}

test "disposition is open to new values" {
    try std.testing.expectEqual(std.lang.Type.Enum.Mode.nonexhaustive, @typeInfo(Disposition).@"enum".mode);
    // A value from a later release still fits.
    const later: Disposition = @fromBackingInt(7);
    try std.testing.expectEqual(@as(u8, 7), @backingInt(later));
}
