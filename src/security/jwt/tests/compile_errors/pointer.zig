//! Must not compile: a pointer among the claims.
const jwt = @import("security").jwt;

const Claims = struct {
    counter: *u8,
};

test {
    comptime jwt.assertClaims(Claims);
}
