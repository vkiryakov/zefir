//! Must not compile: verify with claims of a type that JSON does not give.
const std = @import("std");
const jwt = @import("security").jwt;

const Claims = struct {
    ratio: f16,
};

test {
    var key: jwt.SigningKey = try .hmac(.HS256, "0123456789abcdef0123456789abcdef", .{});
    defer key.deinit();
    const keys = [_]jwt.Key{key.verificationKey()};
    const verifier: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try verifier.verify(Claims, std.testing.io, arena_state.allocator(), "a.b.c", .{});
}
