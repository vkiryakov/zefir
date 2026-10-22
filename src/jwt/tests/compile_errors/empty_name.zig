//! Must not compile: an empty claim name.
const jwt = @import("jwt");

const Claims = struct {
    code: []const u8,

    pub const claim_names = .{ .code = "" };
};

test {
    comptime jwt.assertClaims(Claims);
}
