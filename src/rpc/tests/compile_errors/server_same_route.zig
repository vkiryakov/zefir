const std = @import("std");
const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

fn getUserOf(comptime T: type) fn (*T, *rpc.Context, GetUserRequest) anyerror!User {
    return struct {
        fn get(self: *T, ctx: *rpc.Context, req: GetUserRequest) anyerror!User {
            _ = self;
            _ = ctx;
            return .{ .id = req.id, .name = "Ann" };
        }
    }.get;
}

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});
    pub const getUser = getUserOf(UserHandler);
};

const OtherUserHandler = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});
    pub const getUser = getUserOf(OtherUserHandler);
};

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var users: UserHandler = .{};
    var others: OtherUserHandler = .{};
    var server: rpc.Server = try .init(std.testing.allocator, .{ .transport = memory.serverTransport(), .handlers = .{ &users, &others } });
    defer server.deinit(std.testing.io);
}
