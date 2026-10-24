//! Must not compile: a manager whose events are not a union(enum).
const std = @import("std");
const http = @import("http");

test {
    var live: http.sse.Manager(u32) = .init(std.testing.allocator, .{});
    defer live.deinit(std.testing.io);
}
