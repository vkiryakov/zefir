const rpc = @import("rpc");

const File = struct { fd: i32 };
const User = struct { id: u64, avatar: ?*File };
const GetUserRequest = struct { id: u64 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

test {
    _ = UserApi;
}
