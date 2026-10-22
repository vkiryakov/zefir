const std = @import("std");
const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

fn audit(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
    _ = ctx;
    return next.run();
}

const UserHandler = struct {
    calls: u32 = 0,

    pub const rpc_handler = rpc.implement(UserApi, .{
        // A field without the method run.
        .methods = .{ .getUser = .{ .middleware = .{ audit, .calls } } },
    });

    pub fn getUser(self: *UserHandler, ctx: *rpc.Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var users: UserHandler = .{};
    var server: rpc.Server = try .init(std.testing.allocator, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
    defer server.deinit(std.testing.io);
}
