//! The host and the port of a server, as the client's texts name it:
//! "cache.internal:6379", or "[::1]:6379" for an IPv6 address.

const std = @import("std");
const Io = std.Io;
const Address = @This();

/// A name or an IP address; an IPv6 one without its brackets.
host: []const u8,
port: u16,

pub fn format(a: Address, w: *Io.Writer) Io.Writer.Error!void {
    if (std.mem.findScalar(u8, a.host, ':') != null) return w.print("[{s}]:{d}", .{ a.host, a.port });
    return w.print("{s}:{d}", .{ a.host, a.port });
}

test "an address prints as host:port, an IPv6 one in brackets" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cache.internal:6379", try std.fmt.bufPrint(&buffer, "{f}", .{Address{ .host = "cache.internal", .port = 6379 }}));
    try std.testing.expectEqualStrings("[::1]:6380", try std.fmt.bufPrint(&buffer, "{f}", .{Address{ .host = "::1", .port = 6380 }}));
}
