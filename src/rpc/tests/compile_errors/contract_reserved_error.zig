const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .Unavailable = .{ .code = .unavailable, .app_code = "users.unavailable", .message = "Try again later" },
    },
});

test {
    _ = UserApi;
}
