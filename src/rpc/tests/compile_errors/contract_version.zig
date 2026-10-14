const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 0,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

test {
    _ = UserApi;
}
