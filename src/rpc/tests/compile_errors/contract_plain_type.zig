const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = GetUserRequest },
});

test {
    _ = UserApi;
}
