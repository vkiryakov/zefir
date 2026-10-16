const std = @import("std");
const rpc = @import("rpc");

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
});

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var client: rpc.Client = try .init(std.testing.allocator, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    var r = try client.call(std.testing.io, .root, UserApi, .{ .id = 1 }, .{});
    defer r.deinit();
}
