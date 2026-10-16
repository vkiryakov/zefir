const rpc = @import("rpc");

const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(u64, User) },
});

test {
    _ = UserApi;
}
