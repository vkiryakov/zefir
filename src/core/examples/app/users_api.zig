//! The contract of the users over rpc, as the guide of zefir-rpc writes
//! one: what the shop serves, and what the services that call it import.

const zefir = @import("zefir");
const rpc = zefir.rpc;

pub const User = struct {
    id: u64,
    name: []const u8,
};

pub const GetUserRequest = struct { id: u64 };

pub const UsersApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});
