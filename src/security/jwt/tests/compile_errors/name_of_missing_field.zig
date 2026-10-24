//! Must not compile: claim_names names a field that is not there.
const jwt = @import("jwt");

const Claims = struct {
    is_root: bool = false,

    pub const claim_names = .{ .is_admin = "https://example.com/is_admin" };
};

test {
    comptime jwt.assertClaims(Claims);
}
