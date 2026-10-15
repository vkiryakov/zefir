//! An application of the mailbox transport, the way section 13 of the rpc
//! specification builds one: build.zig hands zefir-rpc and zefir-core of
//! this checkout to the transport's module, so the build has one rpc.
//! CI runs these tests against the commit it checks, not against the
//! zefir that the transport's package pins.

const std = @import("std");
const rpc = @import("zefir-rpc");
const mailbox = @import("rpc-mailbox");

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
    var server = try rpc.Server.init(gpa, .{ .transport = server_side.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);
    try server.start(io);

    var client_side: mailbox.Client = try .init(&broker, .{});
    try client_side.connect(io);
    defer client_side.deinit(io);
    var client = try rpc.Client.init(gpa, .{ .transport = client_side.clientTransport() });
    defer client.deinit();

    var found = try client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
    defer found.deinit();
    try std.testing.expectEqualStrings("Ada", found.outcome.ok.name);

    var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
    defer missing.deinit();
    try std.testing.expectEqualStrings("users.not_found", missing.outcome.failure.app_code);

    // Once the server stops, its queue is gone: the call surely did not run.
    try server.shutdown(io);
    try std.testing.expectError(error.Unavailable, client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{}));
}
