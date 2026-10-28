//! Tests of the users service without a network: `rpc.testing.Server`
//! runs the handlers with the whole chain of `rpc.Server` (authentication,
//! middleware, JSON, validation, the mapping of errors) on a memory
//! transport, and `t.client(.{}, .{})` calls them. Building the server here
//! also runs the compile-time checks of the handlers in `zig build test`.

const std = @import("std");
const rpc = @import("rpc");
const api = @import("users-api");
const mw = @import("middleware.zig");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

const testing = std.testing;

test "a created user can be read back" {
    var repo: UserRepository = .init(testing.allocator);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} }, .{});
    defer t.deinit();
    var client = try t.client(.{}, .{});
    defer client.deinit();

    var created = try client.call(testing.io, .root, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    const ada = switch (created.outcome) {
        .ok => |user| user,
        .failure => return error.TestUnexpectedResult,
    };
    var found = try client.call(testing.io, .root, api.UserApi.getUser, .{ .id = ada.id }, .{});
    defer found.deinit();
    switch (found.outcome) {
        .ok => |user| try testing.expectEqualStrings("Ada Lovelace", user.name),
        .failure => return error.TestUnexpectedResult,
    }
}

test "an unknown user is the failure users.not_found" {
    var repo: UserRepository = .init(testing.allocator);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} }, .{});
    defer t.deinit();
    var client = try t.client(.{}, .{});
    defer client.deinit();

    var r = try client.call(testing.io, .root, api.UserApi.getUser, .{ .id = 42 }, .{});
    defer r.deinit();
    switch (r.outcome) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| {
            try testing.expectEqual(.not_found, failure.code);
            try testing.expectEqualStrings("users.not_found", failure.app_code);
        },
    }
}

test "a request against the rules is not sent" {
    var repo: UserRepository = .init(testing.allocator);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} }, .{});
    defer t.deinit();
    var client = try t.client(.{}, .{});
    defer client.deinit();

    var r = try client.call(testing.io, .root, api.UserApi.createUser, .{ .name = "", .email = "ada@example.com" }, .{});
    defer r.deinit();
    try testing.expect(!r.sent);
    switch (r.outcome) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqualDeep(@as(?[]const u8, "name"), failure.field),
    }
    try testing.expectEqual(0, try repo.count(testing.io));
}

test "a lost response ends the call at its deadline" {
    var repo: UserRepository = .init(testing.allocator);
    defer repo.deinit();
    var users: UserHandler = .{ .repo = &repo };
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} }, .{});
    defer t.deinit();
    var client = try t.client(.{}, .{});
    defer client.deinit();

    // The hooks of the memory transport bring the failures of a network.
    t.memory.loseNextResponse();
    try testing.expectError(error.DeadlineExceeded, client.call(testing.io, .root, api.UserApi.createUser, .{
        .name = "Ada Lovelace",
        .email = "ada@example.com",
    }, .{ .timeout = .fromMilliseconds(100) }));
    // The server ran the call all the same.
    try testing.expectEqual(1, try repo.count(testing.io));
}

/// UserHandler with deleteUser behind the permission users.delete, as the
/// handler of service.zig has it.
const GuardedUsers = struct {
    inner: UserHandler,

    pub const rpc_handler = rpc.implement(api.UserApi, .{
        .methods = .{ .deleteUser = .{ .auth = .required, .middleware = .{mw.requirePermission("users.delete")} } },
    });

    pub fn createUser(self: *GuardedUsers, ctx: *rpc.Context, req: api.CreateUserRequest) UserRepository.Error!api.User {
        return self.inner.createUser(ctx, req);
    }
    pub fn getUser(self: *GuardedUsers, ctx: *rpc.Context, req: api.GetUserRequest) UserRepository.Error!api.User {
        return self.inner.getUser(ctx, req);
    }
    pub fn listUsers(self: *GuardedUsers, ctx: *rpc.Context, req: api.ListUsersRequest) UserRepository.Error!api.ListUsersResponse {
        return self.inner.listUsers(ctx, req);
    }
    pub fn deleteUser(self: *GuardedUsers, ctx: *rpc.Context, req: api.DeleteUserRequest) UserRepository.Error!void {
        return self.inner.deleteUser(ctx, req);
    }
};

test "deleteUser needs the permission users.delete" {
    var repo: UserRepository = .init(testing.allocator);
    defer repo.deinit();
    var users: GuardedUsers = .{ .inner = .{ .repo = &repo } };
    // Every call with credentials, whatever they are, gets this identity.
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "reporting" } };
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users}, .authenticator = &auth }, .{});
    defer t.deinit();
    var client = try t.client(.{}, .{ .credentials = .{ .bearer = "test" } });
    defer client.deinit();

    var created = try client.call(testing.io, .root, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    const id = switch (created.outcome) {
        .ok => |user| user.id,
        .failure => return error.TestUnexpectedResult,
    };
    var denied = try client.call(testing.io, .root, api.UserApi.deleteUser, .{ .id = id }, .{});
    defer denied.deinit();
    switch (denied.outcome) {
        .ok => return error.TestUnexpectedResult,
        .failure => |failure| try testing.expectEqual(.permission_denied, failure.code),
    }

    // Between calls, a test may give the callers another identity.
    auth.identity = .{ .subject = "admin", .permissions = &.{"users.delete"} };
    var deleted = try client.call(testing.io, .root, api.UserApi.deleteUser, .{ .id = id }, .{});
    defer deleted.deinit();
    try testing.expect(deleted.outcome == .ok);
    try testing.expectEqual(0, try repo.count(testing.io));
}
