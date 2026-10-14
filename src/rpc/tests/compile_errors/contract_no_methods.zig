const rpc = @import("rpc");

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{},
});

test {
    _ = UserApi;
}
