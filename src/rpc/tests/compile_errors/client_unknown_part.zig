const std = @import("std");
const rpc = @import("rpc");

test {
    var memory: rpc.testing.MemoryTransport = try .init(std.testing.allocator, .{});
    defer memory.deinit(std.testing.io);
    var client: rpc.Client = try .init(std.testing.allocator, .{ .credentials = .{ .bearer = "t-1" } }, .{
        .transport = memory.clientTransport(),
    });
    defer client.deinit();
}
