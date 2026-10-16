//! The package users-api: the contract of the users service, shared by the
//! service and every client of it. It holds what goes over the wire, the
//! requests, the responses and the errors, and no code of the service.

const rpc = @import("rpc");
const v = @import("validator");

pub const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
};

pub const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,

    // Checked on both sides: the client does not send a request against
    // them, and the server refuses one before its handler runs.
    pub const field_rules = .{
        .name = .{ v.notEmpty, v.maxLength(128) },
        .email = v.email,
    };
};

pub const GetUserRequest = struct { id: u64 };

pub const ListUsersRequest = struct {
    // A field with a default may be missing from the JSON.
    offset: u32 = 0,
    limit: u32 = 20,

    pub const field_rules = .{ .limit = v.range(1, 100) };
};

pub const ListUsersResponse = struct {
    users: []const User,
    total: u64,
};

pub const DeleteUserRequest = struct { id: u64 };

/// The users service, version 1: its methods and the errors its clients
/// see. The route of a method is users.v1.<method>.
pub const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .createUser = rpc.method(CreateUserRequest, User),
        .getUser = rpc.method(GetUserRequest, User),
        .listUsers = rpc.method(ListUsersRequest, ListUsersResponse),
        // void: success carries nothing.
        .deleteUser = rpc.method(DeleteUserRequest, void),
    },
    // An error a handler returns by one of these names reaches the client
    // as this failure; the framework's names (Canceled, DeadlineExceeded,
    // OutOfMemory, …) as their own codes; any other error as `internal`.
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        .EmailTaken = .{ .code = .already_exists, .app_code = "users.email_taken", .message = "Email already taken" },
    },
});

test "the rules of the requests are valid" {
    comptime v.assertRules(CreateUserRequest);
    comptime v.assertRules(ListUsersRequest);
}
