//! An application of the mailbox transport, the way section 13 of the rpc
//! specification builds one: build.zig hands zefir-rpc and zefir-core of
//! this checkout to the transport's module, so the build has one rpc.
//! CI runs these tests against the commit it checks, not against the
//! zefir that the transport's package pins.

const std = @import("std");
const core = @import("zefir-core");
const rpc = @import("zefir-rpc");
const mailbox = @import("rpc-mailbox");

/// A deadline 30 s away, for a test that only needs a stop.
fn far(io: std.Io) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
}

test "the mailbox passes the conformance suite of rpc" {
    var harness: mailbox.testing.Harness = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // Skipped are only the checks the mailbox cannot take: T12 (it does not
    // see a broken link at once), T16 (it delivers at most once) and T17
    // (it needs a live broker that restarts).
    for ([_]rpc.testing.conformance.Check{ .t12, .t16, .t17 }) |check| {
        try std.testing.expect(report.outcome(check) == .skipped);
    }
    try std.testing.expectEqual(@as(usize, 3), report.skippedCount());
}

const api = struct {
    pub const User = struct { id: u64, name: []const u8 };
    pub const GetUserRequest = struct { id: u64 };

    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
        .errors = .{
            .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        },
    });
};

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(api.UserApi, .{});

    pub fn getUser(_: *UserHandler, _: *rpc.Context, req: api.GetUserRequest) error{UserNotFound}!api.User {
        if (req.id != 1) return error.UserNotFound;
        return .{ .id = 1, .name = "Ada" };
    }
};

test "rpc.Server and rpc.Client over the mailbox" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var broker: mailbox.Broker = .init(gpa, .{});
    defer broker.deinit();

    var server_side: mailbox.Server = .init(&broker);
    var users: UserHandler = .{};
    var server = try rpc.Server.init(gpa, .{ .handlers = .{&users} }, .{ .transport = server_side.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var client_side: mailbox.Client = try .init(&broker, .{});
    // Before connect: deinit also frees a client whose connect failed.
    defer client_side.deinit(io);
    try client_side.connect(io);
    var client = try rpc.Client.init(gpa, .{}, .{ .transport = client_side.clientTransport() });
    defer client.deinit();

    var found = try client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
    defer found.deinit();
    switch (found.outcome) {
        .ok => |user| try std.testing.expectEqualStrings("Ada", user.name),
        .failure => return error.TestUnexpectedResult,
    }

    var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
    defer missing.deinit();
    switch (missing.outcome) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expectEqualStrings("users.not_found", failure.app_code),
    }

    // Once the server stops, its queue is gone: the call surely did not run.
    try server.shutdown(io, far(io));
    try std.testing.expectError(error.Unavailable, client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{}));
}

/// A handler on bytes that keeps what the engine gave its call.
const Witness = struct {
    /// When the call's deadline expires, on the awake clock.
    expires: ?i96 = null,
    /// Whether the transport named the client.
    named_peer: bool = true,

    fn handle(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        const w: *Witness = @ptrCast(@alignCast(ptr));
        w.expires = if (ctx.operation().deadline) |deadline| deadline.expires.nanoseconds else null;
        w.named_peer = ctx.peer() != .none;
        return request;
    }
};

const echo_route: rpc.Route = .{ .service = "echo", .version = 1, .method = "echo" };

test "the server's deadline is the client's, the time in the queue counted; the reply queue is not a peer" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var broker: mailbox.Broker = .init(gpa, .{});
    defer broker.deinit();
    var server_side: mailbox.Server = .init(&broker);
    var witness: Witness = .{};
    var server: rpc.RawServer = try .init(gpa, .{
        .transport = server_side.serverTransport(),
        .methods = &.{.{ .route = echo_route, .handler = .{ .ptr = &witness, .handle = Witness.handle } }},
    });
    defer server.deinit(io);
    try server.start(io);
    var client_side: mailbox.Client = try .init(&broker, .{});
    defer client_side.deinit(io);
    try client_side.connect(io);

    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(2));
    const request: rpc.transport.Request = .{
        .route = echo_route,
        .request_id = @splat(7),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(deadline),
        .metadata = &.{},
        .body = "{}",
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const response = try client_side.clientTransport().call(io, &request, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
    try std.testing.expect(response.status == .ok);
    // The request waited in its queue before the server took it: that time
    // came off the budget, so both sides end the call at the same moment.
    try std.testing.expectEqual(@as(?i96, deadline.expires.nanoseconds), witness.expires);
    // The reply queue and the correlation ids are secrets of the call.
    try std.testing.expect(!witness.named_peer);
    try server.shutdown(io, far(io));
}

test "a second connect of the mailbox's client does nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var broker: mailbox.Broker = .init(gpa, .{});
    // No queue of the client is left behind for the broker's deinit.
    defer broker.deinit();
    var client_side: mailbox.Client = try .init(&broker, .{});
    defer client_side.deinit(io);
    try client_side.connect(io);
    try client_side.connect(io);
}
