//! Where a server transport delivers incoming calls. The engine
//! (`rpc.RawServer`) implements it and passes it to
//! `rpc.ServerTransport.start`; the transport calls it from its own tasks
//! until its `close` returns.
//!
//! The path of one call:
//!
//! 1. The transport has read the head of a request and knows the length of
//!    its body: `admit(io, &head, body_len)`, before buffering the body.
//! 2. `.rejected`: the transport answers with the failure in its own format,
//!    marked as not run (the client sees `Response.refused`), and skips the
//!    body. No codec is needed for that.
//! 3. `.accepted`: the transport reads the body into `incoming.body()`,
//!    records the call in its tables and calls `incoming.start(io, reply)`.
//!    If `start` returns a `Failure`, the transport answers as in 2.
//! 4. The engine answers through `reply.send`, at most once, and ends the
//!    call with `reply.release`, exactly once and last.
//!
//! On every accepted call the transport calls exactly one of
//! `incoming.start` and `incoming.abandon`. When the client gives up after
//! `start` (a CANCEL frame, a broken connection), it calls
//! `incoming.cancel`.
//!
//! None of these functions returns `error.Canceled`, and none of them
//! swallows a cancelation request of the transport's task: the next
//! cancelation point of the task still sees it.

const std = @import("std");
const core = @import("core");
const model = @import("model.zig");
const transport = @import("transport.zig");
const rules = @import("rules.zig");
const Incoming = @import("Incoming.zig");
const Reply = @import("Reply.zig");

const Dispatcher = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// The engine's functions behind the interface: one constant table per
/// engine type.
pub const VTable = struct {
    service: *const fn (ptr: *anyopaque) *const Service,
    admit: *const fn (ptr: *anyopaque, io: std.Io, head: *const transport.RequestHead, body_len: usize) Admission,
    fail: *const fn (ptr: *anyopaque, io: std.Io, err: FatalError, diagnostics: ?*const transport.Diagnostics) void,
    routeStats: *const fn (ptr: *anyopaque, route_index: usize) RouteStats,
};

/// The routes and limits of the server.
pub const Service = struct {
    routes: []const model.Route,
    /// How many calls the engine holds at once. An AMQP transport sets its
    /// prefetch from it; a NATS adapter needs a subscription queue at least
    /// this long.
    max_inflight: u32,
    /// The largest request body the engine admits. A transport may refuse a
    /// larger one before reading it, or tell the other side the limit.
    max_request_bytes: usize,
    /// The most metadata entries of a request, repeated keys included.
    max_metadata_entries: u32,
    /// The largest metadata of a request, as `rpc.transport.metadataBytes`
    /// counts it.
    max_metadata_bytes: u32,
};

/// The answer of `admit`.
pub const Admission = union(enum) {
    /// The call is admitted: fill its body, then start or abandon it.
    accepted: Incoming,
    /// The call is refused and did not run. The strings of the failure are
    /// static, literals of the engine.
    rejected: model.Failure,
};

/// Why the whole transport broke for good.
pub const FatalError = error{ Unavailable, AccessDenied, Unexpected };

/// The counters of one route, for NATS micro STATS. A value that owns all
/// it holds: the transport may keep it as long as it needs.
pub const RouteStats = struct {
    requests: u64,
    errors: u64,
    processing_time: std.Io.Duration,
    last_error: ?LastError = null,

    /// The last failure of the route. The engine copies the app code into
    /// the value, so it stays valid as long as the value does.
    pub const LastError = struct {
        code: core.ErrorCode,
        app_code_buffer: [rules.max_app_code_bytes]u8 = undefined,
        app_code_len: u8 = 0,

        /// A copy of `app_code`. One longer than the 128 bytes a contract
        /// may declare is cut before the character that does not fit whole.
        pub fn init(code: core.ErrorCode, app_code: []const u8) LastError {
            var last: LastError = .{ .code = code };
            const len = if (app_code.len <= last.app_code_buffer.len)
                app_code.len
            else
                rules.wholeUtf8Prefix(app_code[0..last.app_code_buffer.len]);
            @memcpy(last.app_code_buffer[0..len], app_code[0..len]);
            last.app_code_len = @intCast(len);
            return last;
        }

        /// The app code, such as "users.not_found".
        pub fn appCode(last: *const LastError) []const u8 {
            return last.app_code_buffer[0..last.app_code_len];
        }
    };
};

/// The routes and limits of the server. A NATS transport subscribes by
/// route; a streaming one tells the other side its frame limit. They do not
/// change while the server lives.
pub fn service(d: Dispatcher) *const Service {
    return d.vtable.service(d.ptr);
}

/// Decides on a call before its body is buffered: the engine reserves
/// memory for `body_len` bytes, so a request that claims a huge length costs
/// nothing. Thread-safe and never waits: when there is no room, the answer
/// is `.rejected` with `resource_exhausted` at once. `head` is borrowed for
/// the duration of `admit`.
///
/// The engine refuses with `resource_exhausted` (limits), `unimplemented`
/// (no such route or codec), `invalid_argument` (metadata, budget),
/// `deadline_exceeded` (no budget left) and `unavailable` (the shutdown
/// grace is over). Broken fields of the transport's own protocol, such as
/// garbage in a budget header, the transport refuses itself with
/// `invalid_argument`.
pub fn admit(d: Dispatcher, io: std.Io, head: *const transport.RequestHead, body_len: usize) Admission {
    return d.vtable.admit(d.ptr, io, head, body_len);
}

/// The whole transport broke for good: its port died, access to the broker
/// was revoked, the NATS connection closed for good. The engine starts
/// draining and wakes `rpc.RawServer.wait` with the error. A second call
/// does nothing. Errors of one call or one connection do not come here.
pub fn fail(d: Dispatcher, io: std.Io, err: FatalError, diagnostics: ?*const transport.Diagnostics) void {
    d.vtable.fail(d.ptr, io, err, diagnostics);
}

/// The counters of `service().routes[route_index]`. Thread-safe and never
/// waits.
pub fn routeStats(d: Dispatcher, route_index: usize) RouteStats {
    return d.vtable.routeStats(d.ptr, route_index);
}

/// A fake engine that records what a transport calls.
const FakeCore = struct {
    service_value: Service = .{
        .routes = &.{.{ .service = "users", .version = 1, .method = "getUser" }},
        .max_inflight = 8,
        .max_request_bytes = 1024,
        .max_metadata_entries = 64,
        .max_metadata_bytes = 16 * 1024,
    },
    admitted: usize = 0,
    failed: ?FatalError = null,
    buffer: [4]u8 = @splat(0),
    reply: ?Reply = null,
    abandoned: bool = false,
    canceled: bool = false,

    const vtable: VTable = .{ .service = serviceFn, .admit = admitFn, .fail = failFn, .routeStats = routeStatsFn };
    const incoming_vtable: Incoming.VTable = .{ .body = bodyFn, .start = startFn, .abandon = abandonFn, .cancel = cancelFn };

    fn dispatcher(self: *FakeCore) Dispatcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn serviceFn(ptr: *anyopaque) *const Service {
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        return &self.service_value;
    }

    fn admitFn(ptr: *anyopaque, io: std.Io, head: *const transport.RequestHead, body_len: usize) Admission {
        _ = io;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        if (body_len > self.buffer.len) return .{ .rejected = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Request too large" } };
        if (!std.mem.eql(u8, head.route.method, "getUser")) return .{ .rejected = .{ .code = .unimplemented, .app_code = "rpc.unknown_method", .message = "Unknown method" } };
        self.admitted = body_len;
        return .{ .accepted = .{ .ptr = self, .vtable = &incoming_vtable } };
    }

    fn failFn(ptr: *anyopaque, io: std.Io, err: FatalError, diagnostics: ?*const transport.Diagnostics) void {
        _ = io;
        _ = diagnostics;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.failed = err;
    }

    fn routeStatsFn(ptr: *anyopaque, route_index: usize) RouteStats {
        _ = ptr;
        return .{ .requests = route_index + 10, .errors = 1, .processing_time = .fromMilliseconds(5), .last_error = .init(.not_found, "users.not_found") };
    }

    fn bodyFn(ptr: *anyopaque) []u8 {
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        return self.buffer[0..self.admitted];
    }

    fn startFn(ptr: *anyopaque, io: std.Io, reply: Reply) ?model.Failure {
        _ = io;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.reply = reply;
        return null;
    }

    /// What the handler's task of a real engine does: answer with the body,
    /// then release the call.
    fn finish(self: *FakeCore, io: std.Io) !void {
        const reply = self.reply.?;
        try reply.send(io, &.{ .status = .ok, .body = self.buffer[0..self.admitted] });
        reply.release(io, if (self.canceled) .canceled else .completed);
    }

    fn abandonFn(ptr: *anyopaque, io: std.Io) void {
        _ = io;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.abandoned = true;
    }

    fn cancelFn(ptr: *anyopaque, io: std.Io) void {
        _ = io;
        const self: *FakeCore = @ptrCast(@alignCast(ptr));
        self.canceled = true;
    }
};

/// A fake transport's reply.
const Echoed = struct {
    body: [4]u8 = @splat(0),
    len: usize = 0,
    released: ?Reply.Disposition = null,

    pub fn send(self: *Echoed, io: std.Io, response: *const model.Response) Reply.SendError!void {
        _ = io;
        @memcpy(self.body[0..response.body.len], response.body);
        self.len = response.body.len;
    }

    pub fn release(self: *Echoed, io: std.Io, disposition: Reply.Disposition) void {
        _ = io;
        self.released = disposition;
    }
};

fn testHead(method: []const u8) transport.RequestHead {
    return .{
        .route = .{ .service = "users", .version = 1, .method = method },
        .request_id = @splat(1),
        .codec = "json",
        .timeout = .fromMilliseconds(500),
        .received_at = .zero,
        .metadata = &.{},
    };
}

test "the last error of a route keeps its own copy of the app code" {
    var source = "users.not_found".*;
    const last: RouteStats.LastError = .init(.not_found, &source);
    source[0] = 'X';
    try std.testing.expectEqual(core.ErrorCode.not_found, last.code);
    try std.testing.expectEqualStrings("users.not_found", last.appCode());

    // Longer than a contract may declare: cut before the character that
    // does not fit whole.
    const exact: [128]u8 = @splat('a');
    try std.testing.expectEqualStrings(&exact, RouteStats.LastError.init(.internal, &exact).appCode());
    const long = @as([127]u8, @splat('b')) ++ "é".*;
    try std.testing.expectEqualStrings(long[0..127], RouteStats.LastError.init(.internal, &long).appCode());
}

test "a transport reaches the engine through the dispatcher and the incoming call" {
    const io = std.testing.io;
    var fake: FakeCore = .{};
    const dispatcher = fake.dispatcher();

    try std.testing.expectEqualStrings("getUser", dispatcher.service().routes[0].method);
    try std.testing.expectEqual(@as(u32, 8), dispatcher.service().max_inflight);
    const stats = dispatcher.routeStats(0);
    try std.testing.expectEqual(@as(u64, 10), stats.requests);
    try std.testing.expectEqualStrings("users.not_found", stats.last_error.?.appCode());

    // Refused before the body is read.
    const head = testHead("getUser");
    switch (dispatcher.admit(io, &head, 1 << 30)) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |failure| try std.testing.expectEqual(core.ErrorCode.resource_exhausted, failure.code),
    }
    const unknown = testHead("deleteUser");
    try std.testing.expect(dispatcher.admit(io, &unknown, 0) == .rejected);

    // Admitted: fill the body, start; the client gives up while it runs.
    const incoming = switch (dispatcher.admit(io, &head, 3)) {
        .accepted => |incoming| incoming,
        .rejected => return error.TestUnexpectedResult,
    };
    @memcpy(incoming.body(), "abc");
    var reply: Echoed = .{};
    try std.testing.expectEqual(@as(?model.Failure, null), incoming.start(io, .init(&reply)));
    incoming.cancel(io);
    try fake.finish(io);
    try std.testing.expectEqualStrings("abc", reply.body[0..reply.len]);
    try std.testing.expectEqual(Reply.Disposition.canceled, reply.released.?);

    // Admitted, but the link broke before the body came.
    const lost = switch (dispatcher.admit(io, &head, 2)) {
        .accepted => |lost| lost,
        .rejected => return error.TestUnexpectedResult,
    };
    lost.abandon(io);
    try std.testing.expect(fake.abandoned);

    var diagnostics: transport.Diagnostics = .{};
    diagnostics.set(.connect, error.ConnectionRefused, "broker gone", .{});
    dispatcher.fail(io, error.Unavailable, &diagnostics);
    try std.testing.expectEqual(error.Unavailable, fake.failed.?);
}
