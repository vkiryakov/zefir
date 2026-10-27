//! Must not compile: the claims of orders with a field named like the
//! registered claim "exp", which jwt sets and checks itself.
const jwt = @import("security").jwt;
const v = @import("validator");

pub const Claims = struct {
    roles: []const []const u8 = &.{},
    exp: i64,

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

test {
    comptime jwt.assertClaims(Claims);
}
