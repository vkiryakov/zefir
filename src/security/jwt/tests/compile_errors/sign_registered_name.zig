//! Must not compile: sign with claims that name a registered claim, which
//! the signer writes itself.
const std = @import("std");
const jwt = @import("security").jwt;

const Claims = struct {
    sub: []const u8,
};

test {
    var key: jwt.SigningKey = try .hmac(.HS256, "0123456789abcdef0123456789abcdef", .{});
    defer key.deinit();
    const signer: jwt.Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const token = try signer.sign(Claims, std.testing.io, std.testing.allocator, &.{ .sub = "user-7" }, .{});
    std.testing.allocator.free(token);
}
