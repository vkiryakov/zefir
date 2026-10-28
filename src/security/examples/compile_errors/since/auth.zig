//! Must not compile: the claims of orders with a field of a type that
//! JSON does not give.
const jwt = @import("security").jwt;
const v = @import("validator");

pub const Claims = struct {
    roles: []const []const u8 = &.{},
    since: [3]u8,

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

test {
    comptime jwt.assertClaims(Claims);
}
