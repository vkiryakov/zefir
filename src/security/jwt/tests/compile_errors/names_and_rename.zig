//! Must not compile: a field named by claim_names and by v.rename at once.
const jwt = @import("jwt");
const v = @import("validator");

const Claims = struct {
    is_root: bool = false,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
    pub const field_rules = .{ .is_root = v.rename("isRoot") };
};

test {
    comptime jwt.assertClaims(Claims);
}
