//! The server side of a transport: it takes calls from the network and
//! delivers them to the engine (`rpc.RawServer`) through the
//! `rpc.transport.Dispatcher` it gets in `start`; the engine runs the
//! handlers. A transport implements it as a type with the methods `start`,
//! `drain`, `close`, `info` and, if it needs one, `isReady`, and hands out
//! `rpc.ServerTransport.init(&transport)`:
//!
//! ```zig
//! pub fn serverTransport(self: *MyTransport) rpc.ServerTransport {
//!     return .init(self);
//! }
//! ```
//!
//! What the transport does while the server runs and stops:
//!
//! - Running: it delivers every call; `admit` decides by route and limits.
//! - Draining, after `drain`: it takes no new calls and delivers only those
//!   its protocol must still take (NATS: messages already on their way to
//!   the subscription; a streaming protocol: calls accepted before its
//!   GOAWAY). `admit` takes them until the shutdown grace is over, then
//!   refuses them with `unavailable`.
//! - The grace is over: the engine has canceled the calls that run and
//!   calls `close`. Once `close` returns, the dispatcher is not called.
//!
//! `drain` and `close` have no `error.Canceled` to return, and they never
//! swallow a cancelation request of the calling task: they lock with
//! `lockUncancelable`, work under `io.swapCancelProtection(.blocked)`, or
//! call `io.recancel()` before they return.

const std = @import("std");
const transport = @import("transport.zig");
const signature = @import("signature.zig");

const ServerTransport = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The transport's functions behind the interface: one constant table per
/// transport type, built by `init`. Entries added later come with defaults,
/// like `isReady`.
pub const VTable = struct {
    start: *const fn (ptr: *anyopaque, io: std.Io, dispatcher: transport.Dispatcher) StartError!void,
    drain: *const fn (ptr: *anyopaque, io: std.Io) void,
    close: *const fn (ptr: *anyopaque, io: std.Io) void,
    info: *const fn (ptr: *anyopaque) transport.Info,
    /// Optional: the transport's own condition of readiness (NATS: the link
    /// to the broker is up). The engine counts start and drain itself.
    isReady: *const fn (ptr: *anyopaque) bool = alwaysReady,
};

/// The errors of `start`. A feature the transport does not support is
/// `OptionUnsupported`, never a panic.
pub const StartError = error{
    AddressInUse,
    AccessDenied,
    Unavailable,
    InvalidConfiguration,
    OptionUnsupported,
    OutOfMemory,
    Unexpected,
} || std.Io.ConcurrentError || std.Io.Cancelable;

/// The default of `VTable.isReady`: ready whenever the engine says so.
pub fn alwaysReady(ptr: *anyopaque) bool {
    _ = ptr;
    return true;
}

/// Starts taking calls. The engine calls it once, from
/// `rpc.RawServer.start`; `io` is the instance the transport runs its tasks
/// on until `close`. The transport opens its port or its subscriptions,
/// confirms them (NATS: `flush`), starts its tasks with `io.concurrent` or
/// `std.Io.Group.concurrent` (not `io.async`, which may run the function at
/// once and never return) and returns when it is ready. On an error it
/// leaves nothing running. After success it may call `dispatcher` from its
/// tasks until `close` returns.
pub fn start(t: ServerTransport, io: std.Io, dispatcher: transport.Dispatcher) StartError!void {
    return t.vtable.start(t.ptr, io, dispatcher);
}

/// Stops taking new calls: NATS drains its subscriptions, so that the
/// broker sends new requests to other replicas; a direct transport stops
/// accepting and tells its connections that it stops (GOAWAY). Returns
/// after a bounded wait, such as canceling and joining its accept task. A
/// second call does nothing.
pub fn drain(t: ServerTransport, io: std.Io) void {
    t.vtable.drain(t.ptr, io);
}

/// Closes the transport. The engine calls it when the shutdown grace is
/// over, also when `deinit` stops the server, whether calls remain or not;
/// never after a failed `start`, which leaves nothing to close. A second
/// call is safe. It includes `drain`; abandons every accepted call that
/// did not start; closes connections and subscriptions, so a late
/// `reply.send` gets `Closed`; cancels and joins its tasks; and returns
/// within a limit the transport documents (NATS: its publish and flush
/// timeouts). The
/// `Reply` of each call not yet released lives until its `release`: the
/// transport frees it only then, and its own `deinit` comes after the
/// server's. It cannot be canceled.
pub fn close(t: ServerTransport, io: std.Io) void {
    t.vtable.close(t.ptr, io);
}

/// What the transport can do. Thread-safe; the values may change.
pub fn info(t: ServerTransport) transport.Info {
    return t.vtable.info(t.ptr);
}

/// Whether the transport can serve now, by its own condition. Thread-safe,
/// never waits.
pub fn isReady(t: ServerTransport) bool {
    return t.vtable.isReady(t.ptr);
}

const interface = "rpc.ServerTransport";

/// The interface of `impl: *T`, where `T` has the methods `start`, `drain`,
/// `close`, `info` and optionally `isReady`: the functions of `VTable` with
/// `self: *T` in place of `*anyopaque`. The table is built at compile time.
/// A missing method or another signature stops the build with a message
/// that names the method and the signature to write.
pub fn init(impl: anytype) ServerTransport {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "transport", Ptr);
    comptime signature.expectMethod(interface, T, "start", fn (Ptr, std.Io, transport.Dispatcher) StartError!void, "pub fn start(self: *@This(), io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void");
    comptime signature.expectMethod(interface, T, "drain", fn (Ptr, std.Io) void, "pub fn drain(self: *@This(), io: std.Io) void");
    comptime signature.expectMethod(interface, T, "close", fn (Ptr, std.Io) void, "pub fn close(self: *@This(), io: std.Io) void");
    comptime signature.expectMethod(interface, T, "info", fn (Ptr) transport.Info, "pub fn info(self: *@This()) rpc.transport.Info");
    const has_is_ready = @hasDecl(T, "isReady");
    if (has_is_ready) comptime signature.expectMethod(interface, T, "isReady", fn (Ptr) bool, "pub fn isReady(self: *@This()) bool");
    const gen = struct {
        fn startFn(ptr: *anyopaque, io: std.Io, dispatcher: transport.Dispatcher) StartError!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.start(self, io, dispatcher);
        }
        fn drainFn(ptr: *anyopaque, io: std.Io) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.drain(self, io);
        }
        fn closeFn(ptr: *anyopaque, io: std.Io) void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            T.close(self, io);
        }
        fn infoFn(ptr: *anyopaque) transport.Info {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.info(self);
        }
        fn isReadyFn(ptr: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.isReady(self);
        }
        const vtable: VTable = if (has_is_ready)
            .{ .start = startFn, .drain = drainFn, .close = closeFn, .info = infoFn, .isReady = isReadyFn }
        else
            .{ .start = startFn, .drain = drainFn, .close = closeFn, .info = infoFn };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}

/// A fake server transport that records the engine's commands.
const Silent = struct {
    started: bool = false,
    drained: bool = false,
    closed: bool = false,
    routes: usize = 0,

    pub fn start(self: *Silent, io: std.Io, dispatcher: transport.Dispatcher) StartError!void {
        _ = io;
        self.routes = dispatcher.service().routes.len;
        self.started = true;
    }
    pub fn drain(self: *Silent, io: std.Io) void {
        _ = io;
        self.drained = true;
    }
    pub fn close(self: *Silent, io: std.Io) void {
        _ = io;
        self.closed = true;
    }
    pub fn info(self: *Silent) transport.Info {
        _ = self;
        return .{ .name = "silent" };
    }
    pub fn serverTransport(self: *Silent) ServerTransport {
        return .init(self);
    }
};

/// A fake server transport with its own readiness.
const Gated = struct {
    open: bool = false,

    pub fn start(self: *Gated, io: std.Io, dispatcher: transport.Dispatcher) StartError!void {
        _ = self;
        _ = io;
        _ = dispatcher;
        return error.AddressInUse;
    }
    pub fn drain(self: *Gated, io: std.Io) void {
        _ = self;
        _ = io;
    }
    pub fn close(self: *Gated, io: std.Io) void {
        _ = self;
        _ = io;
    }
    pub fn info(self: *Gated) transport.Info {
        _ = self;
        return .{ .name = "gated", .propagates_cancellation = true };
    }
    pub fn isReady(self: *Gated) bool {
        return self.open;
    }
};

/// A dispatcher with one route that a fake transport can read.
const OneRoute = struct {
    const service_value: transport.Dispatcher.Service = .{
        .routes = &.{.{ .service = "users", .version = 1, .method = "getUser" }},
        .max_inflight = 1,
        .max_request_bytes = 1,
        .max_metadata_entries = 1,
        .max_metadata_bytes = 1024,
    };
    const vtable: transport.Dispatcher.VTable = .{
        .service = serviceFn,
        .admit = undefined,
        .fail = undefined,
        .routeStats = undefined,
    };
    fn serviceFn(ptr: *anyopaque) *const transport.Dispatcher.Service {
        _ = ptr;
        return &service_value;
    }
};

test "init builds a server transport whose calls reach the methods" {
    const io = std.testing.io;
    var silent: Silent = .{};
    const server = silent.serverTransport();
    var nothing: u8 = 0;
    try server.start(io, .{ .ptr = &nothing, .vtable = &OneRoute.vtable });
    try std.testing.expect(silent.started);
    try std.testing.expectEqual(@as(usize, 1), silent.routes);
    try std.testing.expectEqualStrings("silent", server.info().name);

    // Without its own isReady the transport is always ready.
    try std.testing.expect(server.isReady());
    try std.testing.expect(server.vtable.isReady == &alwaysReady);

    // A copy is the same transport.
    const copy = server;
    copy.drain(io);
    copy.close(io);
    try std.testing.expect(silent.drained and silent.closed);
}

test "init takes the transport's own isReady and errors" {
    const io = std.testing.io;
    var gated: Gated = .{};
    const server: ServerTransport = .init(&gated);
    try std.testing.expect(!server.isReady());
    gated.open = true;
    try std.testing.expect(server.isReady());
    try std.testing.expect(server.info().propagates_cancellation);
    var nothing: u8 = 0;
    try std.testing.expectError(error.AddressInUse, server.start(io, .{ .ptr = &nothing, .vtable = &OneRoute.vtable }));
    server.drain(io);
    server.close(io);
}
