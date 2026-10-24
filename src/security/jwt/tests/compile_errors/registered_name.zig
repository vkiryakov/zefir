//! Must not compile: a field named like a registered claim, which jwt
//! sets and checks itself.
const jwt = @import("security").jwt;

const Claims = struct {
    roles: []const []const u8 = &.{},
    exp: i64,
};

test {
    comptime jwt.assertClaims(Claims);
}
