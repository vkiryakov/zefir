//! The handler of the contract UserApi: a method for each method of the
//! contract, with the request and response types the contract gives it.
//! The server decodes and checks every request before a method runs, and
//! turns what a method returns into the response or the failure.

const rpc = @import("rpc");
const api = @import("users-api");
const UserRepository = @import("UserRepository.zig");

const UserHandler = @This();

repo: *UserRepository,

/// The contract this handler implements, and the settings of its methods:
/// none here, so every method gets the defaults, 3 seconds and anonymous
/// calls allowed.
pub const rpc_handler = rpc.implement(api.UserApi, .{});

pub fn createUser(self: *UserHandler, ctx: *rpc.Context, req: api.CreateUserRequest) UserRepository.Error!api.User {
    // The call's context goes down to the repository: its deadline, its
    // cancellation and its trace.
    return self.repo.insert(ctx.operation(), ctx.io(), ctx.allocator(), req.name, req.email);
}

pub fn getUser(self: *UserHandler, ctx: *rpc.Context, req: api.GetUserRequest) UserRepository.Error!api.User {
    return self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), req.id);
}

pub fn listUsers(self: *UserHandler, ctx: *rpc.Context, req: api.ListUsersRequest) UserRepository.Error!api.ListUsersResponse {
    return self.repo.list(ctx.operation(), ctx.io(), ctx.allocator(), req.offset, req.limit);
}

pub fn deleteUser(self: *UserHandler, ctx: *rpc.Context, req: api.DeleteUserRequest) UserRepository.Error!void {
    return self.repo.remove(ctx.operation(), ctx.io(), req.id);
}
