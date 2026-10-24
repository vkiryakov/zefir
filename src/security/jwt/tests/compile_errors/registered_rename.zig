//! Must not compile: a field renamed to a registered claim.
const jwt = @import("security").jwt;
const v = @import("validator");

const Claims = struct {
    issuer: []const u8,

    pub const field_rules = .{ .issuer = v.rename("iss") };
};

test {
    comptime jwt.assertClaims(Claims);
}
