//! Must not compile: a pointer among the claims.
const jwt = @import("jwt");

const Claims = struct {
    counter: *u8,
};

test {
    comptime jwt.assertClaims(Claims);
}
