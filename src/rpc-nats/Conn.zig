//! What the NATS transport of rpc needs from a NATS connection: six
//! operations and a check of the link. An adapter of a NATS library fills
//! in the table and hands out `rpc_nats.Conn.init(&adapter)`; rpc never
//! sees the library's types. Subjects, headers, statuses, the inbox and
//! the budget are written once, in `rpc_nats.Transport`, so every library
//! puts the same bytes on the wire.
//!
//! ```zig
//! pub fn conn(self: *MyAdapter) rpc_nats.Conn {
//!     return .init(self);
//! }
//! ```
//!
//! What an adapter keeps to:
//!
//! - `subscribe` sends SUB before it returns, in order with the publishes
//!   that follow on the connection.
//! - The connection sends CONNECT with `headers` and `no_responders` on.
//! - `next`, `flush` and a `publish` that waits for room are cancelation
//!   points of `std.Io`.
//! - The connection runs on the `std.Io` instance that rpc runs on:
//!   otherwise canceling a task would not end a wait inside the library.
//! - An `InMsg` lives until its `release`, which may come from any task.
//! - The queue of a subscription (its pending limits) holds at least the
//!   server's `max_inflight` messages: in NATS it is where messages are
//!   dropped as a slow consumer, not flow control. The transport cannot set
//!   it; the adapter does.
//! - The application owns the connection: the transport never closes it,
//!   and is deinitialized before it.

const std = @import("std");

const Conn = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// One header of a message to send.
pub const Header = struct { name: []const u8, value: []const u8 };

/// A message to send; its slices are borrowed for the duration of the call.
pub const OutMsg = struct {
    subject: []const u8,
    reply_to: ?[]const u8 = null,
    /// Sent in this order. The adapter's library writes the `NATS/1.0`
    /// block; none of them is ever named `Status` or `Description`.
    headers: []const Header = &.{},
    payload: []const u8 = "",
};

/// A message received; it belongs to the adapter until `release`.
pub const InMsg = struct {
    subject: []const u8,
    reply_to: ?[]const u8,
    /// The `NATS/1.0` block as it came, through the blank line; "" when the
    /// message has none. The transport reads it itself, so a status and a
    /// header look the same with every library.
    header_block: []const u8,
    payload: []const u8,
    context: *anyopaque,
    release_fn: *const fn (context: *anyopaque) void,

    /// Gives the message back to the adapter; once, from any task.
    pub fn release(msg: InMsg) void {
        msg.release_fn(msg.context);
    }
};

/// A subscription, as the adapter knows it.
pub const Sub = *anyopaque;

pub const Error = error{
    /// The library refused the subject.
    InvalidSubject,
    /// The message is over the server's `max_payload`.
    PayloadTooLarge,
    /// The server's permissions do not allow the publish or the
    /// subscription.
    PermissionDenied,
    /// Messages of a subscription were dropped: they did not fit its queue.
    SlowConsumer,
    /// No link to the server right now; the library reconnects.
    Disconnected,
    /// The connection is closed for good.
    ConnectionClosed,
    OutOfMemory,
} || std.Io.Cancelable || std.Io.Timeout.Error;

/// The adapter's functions behind the interface: one constant table per
/// adapter type, built by `init`. Entries added later come with defaults,
/// like `isConnected`.
pub const VTable = struct {
    /// PUB or HPUB, in order with SUB and UNSUB of this connection. Waits for
    /// room in the library's send buffer no longer than `timeout`.
    publish: *const fn (ptr: *anyopaque, io: std.Io, msg: OutMsg, timeout: std.Io.Timeout) Error!void,
    /// SUB, in the queue group `queue` when it is not null; the SUB is
    /// queued before it returns.
    subscribe: *const fn (ptr: *anyopaque, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Error!Sub,
    /// The next message; null once the subscription has ended (drained or
    /// unsubscribed). One task waits at a time; a cancelation point.
    next: *const fn (ptr: *anyopaque, io: std.Io, sub: Sub, timeout: std.Io.Timeout) Error!?InMsg,
    /// UNSUB that keeps what is on its way and in the queue: `next` hands it
    /// out, then null. Wakes a task that waits in `next`.
    drain: *const fn (ptr: *anyopaque, io: std.Io, sub: Sub) Error!void,
    /// Ends the subscription now and frees it; no task may wait in its
    /// `next`.
    unsubscribe: *const fn (ptr: *anyopaque, io: std.Io, sub: Sub) void,
    /// Waits until the server has processed everything sent before (PING
    /// and PONG); the server's verdict on a SUB comes here.
    flush: *const fn (ptr: *anyopaque, io: std.Io, timeout: std.Io.Timeout) Error!void,
    /// Optional: whether the link to the server is up now. By default it
    /// always is: an adapter of a library that cannot tell loses the fast
    /// `Unavailable` while the library reconnects.
    isConnected: *const fn (ptr: *anyopaque) bool = alwaysConnected,
};

/// The default of `VTable.isConnected`: always connected.
pub fn alwaysConnected(ptr: *anyopaque) bool {
    _ = ptr;
    return true;
}

/// PUB or HPUB of `msg`, by the rules of `VTable.publish`.
pub fn publish(c: Conn, io: std.Io, msg: OutMsg, timeout: std.Io.Timeout) Error!void {
    return c.vtable.publish(c.ptr, io, msg, timeout);
}

/// SUB to `subject`, in the queue group `queue` when it is not null, by
/// the rules of `VTable.subscribe`.
pub fn subscribe(c: Conn, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Error!Sub {
    return c.vtable.subscribe(c.ptr, io, subject, queue, timeout);
}

/// The next message of `sub`, or null once it has ended, by the rules of
/// `VTable.next`.
pub fn next(c: Conn, io: std.Io, sub: Sub, timeout: std.Io.Timeout) Error!?InMsg {
    return c.vtable.next(c.ptr, io, sub, timeout);
}

/// UNSUB that keeps what is on its way, by the rules of `VTable.drain`.
pub fn drain(c: Conn, io: std.Io, sub: Sub) Error!void {
    return c.vtable.drain(c.ptr, io, sub);
}

/// Ends `sub` now and frees it, by the rules of `VTable.unsubscribe`.
pub fn unsubscribe(c: Conn, io: std.Io, sub: Sub) void {
    c.vtable.unsubscribe(c.ptr, io, sub);
}

/// Waits until the server has processed everything sent before, by the
/// rules of `VTable.flush`.
pub fn flush(c: Conn, io: std.Io, timeout: std.Io.Timeout) Error!void {
    return c.vtable.flush(c.ptr, io, timeout);
}

/// Thread-safe and never waits.
pub fn isConnected(c: Conn) bool {
    return c.vtable.isConnected(c.ptr);
}

const interface = "rpc_nats.Conn";

/// The interface of `impl: *T`, where `T` has the methods `publish`,
/// `subscribe`, `next`, `drain`, `unsubscribe`, `flush` and optionally
/// `isConnected`: the functions of `VTable` with `self: *T` in place of
/// `*anyopaque`. The table is built at compile time. A missing method or
/// another signature stops the build with a message that names the method
/// and the signature to write.
pub fn init(impl: anytype) Conn {
    const Ptr = @TypeOf(impl);
    const T = comptime expectPointer(Ptr);
    comptime expectMethod(T, "publish", fn (Ptr, std.Io, OutMsg, std.Io.Timeout) Error!void, "pub fn publish(self: *@This(), io: std.Io, msg: rpc_nats.Conn.OutMsg, timeout: std.Io.Timeout) rpc_nats.Conn.Error!void");
    comptime expectMethod(T, "subscribe", fn (Ptr, std.Io, []const u8, ?[]const u8, std.Io.Timeout) Error!Sub, "pub fn subscribe(self: *@This(), io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) rpc_nats.Conn.Error!rpc_nats.Conn.Sub");
    comptime expectMethod(T, "next", fn (Ptr, std.Io, Sub, std.Io.Timeout) Error!?InMsg, "pub fn next(self: *@This(), io: std.Io, sub: rpc_nats.Conn.Sub, timeout: std.Io.Timeout) rpc_nats.Conn.Error!?rpc_nats.Conn.InMsg");
    comptime expectMethod(T, "drain", fn (Ptr, std.Io, Sub) Error!void, "pub fn drain(self: *@This(), io: std.Io, sub: rpc_nats.Conn.Sub) rpc_nats.Conn.Error!void");
    comptime expectMethod(T, "unsubscribe", fn (Ptr, std.Io, Sub) void, "pub fn unsubscribe(self: *@This(), io: std.Io, sub: rpc_nats.Conn.Sub) void");
    comptime expectMethod(T, "flush", fn (Ptr, std.Io, std.Io.Timeout) Error!void, "pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) rpc_nats.Conn.Error!void");
    const has_is_connected = @hasDecl(T, "isConnected");
    if (has_is_connected) comptime expectMethod(T, "isConnected", fn (Ptr) bool, "pub fn isConnected(self: *@This()) bool");
    const gen = struct {
        fn publishFn(ptr: *anyopaque, io: std.Io, msg: OutMsg, timeout: std.Io.Timeout) Error!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.publish(self, io, msg, timeout);
        }
        fn subscribeFn(ptr: *anyopaque, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Error!Sub {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.subscribe(self, io, subject, queue, timeout);
        }
        fn nextFn(ptr: *anyopaque, io: std.Io, sub: Sub, timeout: std.Io.Timeout) Error!?InMsg {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.next(self, io, sub, timeout);
        }
        fn drainFn(ptr: *anyopaque, io: std.Io, sub: Sub) Error!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.drain(self, io, sub);
        }
        fn unsubscribeFn(ptr: *anyopaque, io: std.Io, sub: Sub) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.unsubscribe(self, io, sub);
        }
        fn flushFn(ptr: *anyopaque, io: std.Io, timeout: std.Io.Timeout) Error!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.flush(self, io, timeout);
        }
        fn isConnectedFn(ptr: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.isConnected(self);
        }
        const vtable: VTable = .{
            .publish = publishFn,
            .subscribe = subscribeFn,
            .next = nextFn,
            .drain = drainFn,
            .unsubscribe = unsubscribeFn,
            .flush = flushFn,
            .isConnected = if (has_is_connected) isConnectedFn else alwaysConnected,
        };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}

/// The type that `Ptr` points to. Stops the build unless `Ptr` is a pointer
/// to one mutable struct, union, enum or opaque.
fn expectPointer(comptime Ptr: type) type {
    const not_a_pointer = interface ++ ".init: pass a pointer to the adapter, e.g. &adapter; got " ++ @typeName(Ptr);
    const ptr = switch (@typeInfo(Ptr)) {
        .pointer => |ptr| ptr,
        else => @compileError(not_a_pointer),
    };
    if (ptr.size != .one) @compileError(not_a_pointer);
    switch (@typeInfo(ptr.child)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => @compileError(not_a_pointer),
    }
    if (ptr.attrs.@"const")
        @compileError(interface ++ ".init: the adapter must be mutable, declared with var; got " ++ @typeName(Ptr));
    return ptr.child;
}

/// Stops the build unless `T` has a method `name` of type `Expected`.
fn expectMethod(comptime T: type, comptime name: []const u8, comptime Expected: type, comptime signature: []const u8) void {
    if (!@hasDecl(T, name))
        @compileError(interface ++ ".init: " ++ @typeName(T) ++ " has no method " ++ name ++ "; expected " ++ signature);
    if (@TypeOf(@field(T, name)) != Expected)
        @compileError(interface ++ ".init: " ++ @typeName(T) ++ "." ++ name ++ " has another signature; expected " ++ signature);
}

const testing = std.testing;

/// An adapter that records what the transport asks of it.
const Recorder = struct {
    calls: std.ArrayList([]const u8) = .empty,
    message: u8 = 0,
    connected: bool = true,

    fn record(self: *Recorder, what: []const u8) void {
        self.calls.appendBounded(what) catch {};
    }

    pub fn publish(self: *Recorder, io: std.Io, msg: OutMsg, timeout: std.Io.Timeout) Error!void {
        _ = io;
        _ = timeout;
        self.record(msg.subject);
    }
    pub fn subscribe(self: *Recorder, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Error!Sub {
        _ = io;
        _ = timeout;
        self.record(subject);
        self.record(queue orelse "no queue");
        return self;
    }
    pub fn next(self: *Recorder, io: std.Io, sub: Sub, timeout: std.Io.Timeout) Error!?InMsg {
        _ = io;
        _ = timeout;
        self.record("next");
        if (sub != @as(Sub, self)) return error.InvalidSubject;
        return .{ .subject = "s", .reply_to = null, .header_block = "", .payload = "p", .context = &self.message, .release_fn = releaseMessage };
    }
    pub fn drain(self: *Recorder, io: std.Io, sub: Sub) Error!void {
        _ = io;
        _ = sub;
        self.record("drain");
    }
    pub fn unsubscribe(self: *Recorder, io: std.Io, sub: Sub) void {
        _ = io;
        _ = sub;
        self.record("unsubscribe");
    }
    pub fn flush(self: *Recorder, io: std.Io, timeout: std.Io.Timeout) Error!void {
        _ = io;
        _ = timeout;
        self.record("flush");
        return error.PermissionDenied;
    }

    fn releaseMessage(context: *anyopaque) void {
        const message: *u8 = @ptrCast(context);
        message.* += 1;
    }
};

test "calls through the interface reach the adapter's methods" {
    var buffer: [16][]const u8 = undefined;
    var adapter: Recorder = .{ .calls = .initBuffer(&buffer) };
    const conn: Conn = .init(&adapter);
    const io = testing.io;
    try conn.publish(io, .{ .subject = "users.v1.getUser" }, .none);
    const sub = try conn.subscribe(io, "_INBOX.x.*", null, .none);
    const msg = (try conn.next(io, sub, .none)).?;
    try testing.expectEqualStrings("p", msg.payload);
    msg.release();
    try testing.expectEqual(@as(u8, 1), adapter.message);
    try conn.drain(io, sub);
    conn.unsubscribe(io, sub);
    try testing.expectError(error.PermissionDenied, conn.flush(io, .none));
    const expected = [_][]const u8{ "users.v1.getUser", "_INBOX.x.*", "no queue", "next", "drain", "unsubscribe", "flush" };
    try testing.expectEqual(expected.len, adapter.calls.items.len);
    for (expected, adapter.calls.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "an adapter without isConnected is always connected; one with it is asked" {
    var plain: Recorder = .{};
    try testing.expect(Conn.init(&plain).isConnected());

    const Linked = struct {
        inner: Recorder = .{},
        up: bool = false,
        pub fn publish(self: *@This(), io: std.Io, msg: OutMsg, timeout: std.Io.Timeout) Error!void {
            return self.inner.publish(io, msg, timeout);
        }
        pub fn subscribe(self: *@This(), io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Error!Sub {
            return self.inner.subscribe(io, subject, queue, timeout);
        }
        pub fn next(self: *@This(), io: std.Io, sub: Sub, timeout: std.Io.Timeout) Error!?InMsg {
            return self.inner.next(io, sub, timeout);
        }
        pub fn drain(self: *@This(), io: std.Io, sub: Sub) Error!void {
            return self.inner.drain(io, sub);
        }
        pub fn unsubscribe(self: *@This(), io: std.Io, sub: Sub) void {
            self.inner.unsubscribe(io, sub);
        }
        pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) Error!void {
            return self.inner.flush(io, timeout);
        }
        pub fn isConnected(self: *@This()) bool {
            return self.up;
        }
    };
    var linked: Linked = .{};
    const conn: Conn = .init(&linked);
    try testing.expect(!conn.isConnected());
    linked.up = true;
    try testing.expect(conn.isConnected());
}

test "the interface is a pointer and a table: copies share the adapter" {
    var adapter: Recorder = .{};
    const a: Conn = .init(&adapter);
    const b = a;
    try testing.expectEqual(a.ptr, b.ptr);
    try testing.expectEqual(a.vtable, b.vtable);
    // One table per adapter type.
    var other: Recorder = .{};
    try testing.expectEqual(a.vtable, Conn.init(&other).vtable);
}
