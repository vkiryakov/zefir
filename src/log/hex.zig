//! Binary data in log records: `.digest = zefir.log.hex(&digest)`.

const std = @import("std");

/// Wraps `bytes` so they are logged as lowercase hex, `"deadbeef"`, rather
/// than as text. The bytes must stay alive until the call returns.
pub fn hex(bytes: []const u8) Hex {
    return .{ .bytes = bytes };
}

pub const Hex = struct {
    bytes: []const u8,

    pub fn format(h: Hex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const digits = "0123456789abcdef";
        for (h.bytes) |b| try w.writeAll(&.{ digits[b >> 4], digits[b & 0xf] });
    }
};

test "bytes print as lowercase hex" {
    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{hex(&.{ 0x00, 0x7f, 0xab, 0xff })});
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("007fabff", formatted);
}
