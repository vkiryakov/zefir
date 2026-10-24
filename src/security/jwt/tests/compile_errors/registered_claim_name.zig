//! Must not compile: a claim name of claim_names that is a registered
//! claim.
const jwt = @import("security").jwt;

const Claims = struct {
    audience: []const u8,

    pub const claim_names = .{ .audience = "aud" };
};

test {
    comptime jwt.assertClaims(Claims);
}
