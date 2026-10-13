//! The client side of a transport: it sends one request and waits for its
//! response. The engine (`rpc.RawClient`) calls it. A transport implements
//! it as a type with the methods `call` and `info` and hands out
//! `rpc.ClientTransport.init(&transport)`:
//!
//! ```zig
//! pub fn clientTransport(self: *MyTransport) rpc.ClientTransport {
//!     return .init(self);
//! }
//! ```
//!
//! The rules of `call`:
//!
//! 1. Concurrency. Any number of tasks and threads call it at once. Shared
//!    state is guarded with `std.Io` primitives (`Io.Mutex`, `Io.Condition`,
//!    `Io.Event`, `Io.Queue`): a lock of the OS or of a C library would stop
//!    a whole thread of an event loop such as zio. `info` is thread-safe
//!    too, and its values may change, such as `max_body_bytes` after a
//!    reconnect.
//! 2. Waiting suspends the task through `io`, never the OS thread. `io` is
//!    the instance the transport was created with, and the one the library
//!    under it runs on: otherwise canceling the task would not end a wait
//!    inside the library. In Debug the transport checks it by comparing
//!    `io.vtable` with that of its own instance.
//! 3. Deadline. With less than 1 ms left until `request.ctx.deadline`,
//!    `call` returns `error.Timeout` without sending. Otherwise it sends the
//!    budget left, measured right before sending, and waits for the response
//!    no longer than the deadline. A response that comes after `Timeout` is
//!    dropped.
//! 4. Cancelation. `call` is a cancelation point. It returns
//!    `error.Canceled` if and only if the caller's task was canceled, before
//!    the call or during it; never for another reason (a cancelation on the
//!    server side, a closed connection and the deadline have errors of their
//!    own), and it never swallows one. After any return, `Canceled` and
//!    `Timeout` included, the transport keeps no reference to the caller's
//!    memory and none of its tasks touches it. When the request has already
//!    left and `info().propagates_cancellation` is set, the transport tells
//!    the server that the call was canceled. After `Canceled` the engine
//!    calls `io.recancel()`, which in Debug checks that a cancelation really
//!    came: a false `Canceled` panics there.
//! 5. Memory. `request` and its slices are borrowed until `call` returns.
//!    Everything the returned `Response` points to comes from
//!    `options.allocator`, allocated during the call only: the transport
//!    never uses that allocator at the same time as the caller.
//! 6. A failure of the server is not an error: a response with
//!    `status = .failure` comes back as a value. A refusal at admission
//!    comes so too, with `refused = true`: the call did not run.

const std = @import("std");
const model = @import("model.zig");
const transport = @import("transport.zig");
const signature = @import("signature.zig");

const ClientTransport = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The transport's functions behind the interface: one constant table per
/// transport type, built by `init`. Entries added later come with defaults.
pub const VTable = struct {
    call: *const fn (ptr: *anyopaque, io: std.Io, request: *const transport.Request, options: CallOptions) CallError!model.Response,
    info: *const fn (ptr: *anyopaque) transport.Info,
};

pub const CallOptions = struct {
    /// The allocator for the metadata, the body and the failure strings of
    /// the response; usually the arena of the call. The caller frees them.
    allocator: std.mem.Allocator,
    /// A response body larger than this is `error.ResponseTooLarge`.
    max_response_bytes: usize,
    /// Response metadata beyond these limits is `error.ResponseTooLarge`
    /// too: a response has the limits of a request. Entries count with
    /// repeated keys; bytes count as `rpc.transport.metadataBytes` does.
    max_response_metadata_entries: u32 = 64,
    max_response_metadata_bytes: u32 = 16 * 1024,
    /// When not null, the transport puts details of an error here.
    diagnostics: ?*transport.Diagnostics = null,
};

/// The errors of `call`. "Not sent" errors are safe to retry; after the
/// others the call may have run, so only an idempotent call is retried.
pub const CallError = error{
    /// Not sent, or the server surely did not start the call: no link, the
    /// server drains, NATS has no responders. On NATS also: no server serves
    /// this route, a typo or another version, not always temporary.
    Unavailable,
    /// The transport or the broker did not allow sending (NATS permissions,
    /// AMQP access); not sent.
    AccessDenied,
    /// Sending started and the link broke before the response; the call may
    /// have run.
    ConnectionLost,
    /// The transport's own limit of calls in flight; not sent.
    TooManyPendingRequests,
    /// Larger than the transport or the other side accepts; not sent.
    RequestTooLarge,
    /// The response is beyond `CallOptions` limits and was dropped; the call
    /// ran.
    ResponseTooLarge,
    /// The other side broke the protocol; the call may have run.
    ProtocolViolation,
    /// No protocol version or codec in common; not sent.
    UnsupportedProtocol,
    /// The owner closed the transport; not sent.
    Closed,
    OutOfMemory,
    /// Any other error of the transport's library; details in
    /// `CallOptions.diagnostics`.
    Unexpected,
} || std.Io.Cancelable || std.Io.Timeout.Error;

/// Sends `request` and waits for its response, by the rules at the top of
/// this file.
pub fn call(t: ClientTransport, io: std.Io, request: *const transport.Request, options: CallOptions) CallError!model.Response {
    return t.vtable.call(t.ptr, io, request, options);
}

/// What the transport can do. Thread-safe; the values may change.
pub fn info(t: ClientTransport) transport.Info {
    return t.vtable.info(t.ptr);
}

const interface = "rpc.ClientTransport";

/// The interface of `impl: *T`, where `T` has the methods `call` and `info`:
/// the functions of `VTable` with `self: *T` in place of `*anyopaque`. The
/// table is built at compile time. A missing method or another signature
/// stops the build with a message that names the method and the signature
/// to write.
pub fn init(impl: anytype) ClientTransport {
    const Ptr = @TypeOf(impl);
    const T = signature.expectPointer(interface, "transport", Ptr);
    comptime signature.expectMethod(interface, T, "call", fn (Ptr, std.Io, *const transport.Request, CallOptions) CallError!model.Response, "pub fn call(self: *@This(), io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response");
    comptime signature.expectMethod(interface, T, "info", fn (Ptr) transport.Info, "pub fn info(self: *@This()) rpc.transport.Info");
    const gen = struct {
        fn callFn(ptr: *anyopaque, io: std.Io, request: *const transport.Request, options: CallOptions) CallError!model.Response {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.call(self, io, request, options);
        }
        fn infoFn(ptr: *anyopaque) transport.Info {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return T.info(self);
        }
        const vtable: VTable = .{ .call = callFn, .info = infoFn };
    };
    return .{ .ptr = impl, .vtable = &gen.vtable };
}

/// A fake transport that answers with the request's body.
const Echo = struct {
    calls: std.atomic.Value(u32) = .init(0),

    pub fn call(self: *Echo, io: std.Io, request: *const transport.Request, options: CallOptions) CallError!model.Response {
        _ = io;
        _ = self.calls.fetchAdd(1, .monotonic);
        if (request.body.len > options.max_response_bytes) {
            if (options.diagnostics) |d| d.set(.receive, null, "echo of {d} bytes is over {d}", .{ request.body.len, options.max_response_bytes });
            return error.ResponseTooLarge;
        }
        return .{ .status = .ok, .body = try options.allocator.dupe(u8, request.body) };
    }

    pub fn info(self: *Echo) transport.Info {
        _ = self;
        return .{ .name = "echo", .reports_unprocessed = true };
    }

    pub fn clientTransport(self: *Echo) ClientTransport {
        return .init(self);
    }
};

test "init builds a transport whose calls reach the methods" {
    const core = @import("core");
    const io = std.testing.io;
    var echo: Echo = .{};
    const client = echo.clientTransport();
    try std.testing.expectEqualStrings("echo", client.info().name);
    try std.testing.expect(client.info().reports_unprocessed);

    const request: transport.Request = .{
        .route = .{ .service = "users", .version = 1, .method = "getUser" },
        .request_id = @splat(7),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(5))),
        .metadata = &.{.{ .key = "traceparent", .value = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }},
        .body = "{\"id\":\"42\"}",
    };
    const response = try client.call(io, &request, .{ .allocator = std.testing.allocator, .max_response_bytes = 1024 });
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.status == .ok);
    try std.testing.expectEqualStrings("{\"id\":\"42\"}", response.body);

    // A copy is the same transport: two pointers, nothing else.
    const copies = [_]ClientTransport{ client, client };
    var diagnostics: transport.Diagnostics = .{};
    try std.testing.expectError(error.ResponseTooLarge, copies[1].call(io, &request, .{
        .allocator = std.testing.allocator,
        .max_response_bytes = 4,
        .diagnostics = &diagnostics,
    }));
    try std.testing.expectEqualStrings("echo of 11 bytes is over 4", diagnostics.message());
    try std.testing.expectEqual(@as(u32, 2), echo.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(ClientTransport));
}
