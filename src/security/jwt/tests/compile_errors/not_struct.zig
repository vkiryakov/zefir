//! Must not compile: claims that are not a struct.
const jwt = @import("jwt");

const Claims = u32;

test {
    comptime jwt.assertClaims(Claims);
}
