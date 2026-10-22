const std = @import("std");
const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(self: *UserHandler, ctx: *rpc.Context, req: GetUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

fn logCalls(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
    _ = ctx;
    return next.run();
}

const RateLimiter = struct {
    per_minute: u32,

    pub fn run(self: *RateLimiter, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        _ = self;
        _ = ctx;
        return next.run();
    }
};

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var users: UserHandler = .{};
    const limiter: RateLimiter = .{ .per_minute = 100 };
    // The limiter by value: a link of the server is a pointer to an object.
    var server: rpc.Server = try .init(std.testing.allocator, .{
        .handlers = .{&users},
        .middleware = .{ logCalls, limiter },
    }, .{
        .transport = memory.serverTransport(),
    });
    defer server.deinit(std.testing.io);
}
