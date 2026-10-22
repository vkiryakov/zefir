//! Must not compile: an event whose name would break the line of its
//! event: field.
const std = @import("std");
const http = @import("http");

const LiveEvent = union(enum) { @"todo\ncreated": u64 };

test {
    var live: http.sse.Manager(LiveEvent) = .init(std.testing.allocator, .{});
    defer live.deinit(std.testing.io);
}
