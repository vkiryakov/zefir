//! Must not compile: two fields with one claim name.
const jwt = @import("security").jwt;

const Claims = struct {
    role: []const u8,
    admin_role: []const u8,

    pub const claim_names = .{ .admin_role = "role" };
};

test {
    comptime jwt.assertClaims(Claims);
}
