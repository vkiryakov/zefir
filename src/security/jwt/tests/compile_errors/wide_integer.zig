//! Must not compile: an integer wider than 64 bits.
const jwt = @import("jwt");

const Claims = struct {
    total: u128,
};

test {
    comptime jwt.assertClaims(Claims);
}
