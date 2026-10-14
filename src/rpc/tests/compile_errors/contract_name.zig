const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "user service",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

test {
    _ = UserApi;
}
