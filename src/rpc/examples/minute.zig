const std = @import("std");
const log = @import("log");
const rpc = @import("rpc");

// The contract: shared by the server and its clients, usually in a package of its own.
const User = struct { id: u64, name: []const u8 };
const GetUserRequest = struct { id: u64 };
const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

// The handler: a method for each method of the contract.
const Users = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(_: *Users, _: *rpc.Context, req: GetUserRequest) error{UserNotFound}!User {
        if (req.id != 42) return error.UserNotFound;
        return .{ .id = 42, .name = "Ada" };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();

    // The memory transport keeps both sides in this process; on NATS, rpc_nats.Transport.
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var users: Users = .{};
    var server = try rpc.Server.init(gpa, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{}, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    for ([_]u64{ 42, 7 }) |id| {
        var result = try client.call(io, .root, UserApi.getUser, .{ .id = id }, .{});
        defer result.deinit();
        switch (result.outcome) {
            .ok => |user| logger.info("User found", .{ .id = user.id, .name = user.name }),
            .failure => |failure| logger.warn("No user", .{ .id = id, .app_code = failure.app_code }),
        }
    }
}
