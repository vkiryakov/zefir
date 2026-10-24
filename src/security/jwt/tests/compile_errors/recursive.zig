//! Must not compile: claims that contain themselves.
const jwt = @import("security").jwt;

const Claims = struct {
    name: []const u8,
    children: []const @This() = &.{},
};

test {
    comptime jwt.assertClaims(Claims);
}
