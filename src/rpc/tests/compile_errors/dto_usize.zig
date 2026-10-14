const rpc = @import("rpc");

const ListUsersRequest = struct { offset: u32 = 0, limit: usize = 50 };
const User = struct { id: u64, name: []const u8 };
const ListUsersResponse = struct { users: []const User, total: u64 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .listUsers = rpc.method(ListUsersRequest, ListUsersResponse) },
});

test {
    _ = UserApi;
}
