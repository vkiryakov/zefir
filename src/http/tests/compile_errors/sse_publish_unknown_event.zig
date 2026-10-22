//! Must not compile: publish of an event that the stream's union does not
//! have.
const std = @import("std");
const http = @import("http");

const Todo = struct { id: u64, title: []const u8 };
const LiveEvent = union(enum) { @"todo.created": Todo };

test {
    var live: http.sse.Manager(LiveEvent) = .init(std.testing.allocator, .{});
    defer live.deinit(std.testing.io);
    try live.publish(.root, std.testing.io, "ann", .{ .event = .{ .@"todo.archived" = .{ .id = 1, .title = "Buy milk" } } });
}
