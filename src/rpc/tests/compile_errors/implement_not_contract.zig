const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(GetUserRequest, .{});
};

test {
    _ = UserHandler.rpc_handler;
}
