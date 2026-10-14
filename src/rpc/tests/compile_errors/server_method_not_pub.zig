const std = @import("std");
const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});

    // Without pub, the method is not open to calls.
    fn getUser(self: *UserHandler, ctx: *rpc.Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var users: UserHandler = .{};
    var server: rpc.Server = try .init(std.testing.allocator, .{ .transport = memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(std.testing.io);
}
