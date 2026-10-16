const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{
        .methods = .{ .getUser = .{ .auth = .maybe } },
    });
};

test {
    _ = UserHandler.rpc_handler;
}
