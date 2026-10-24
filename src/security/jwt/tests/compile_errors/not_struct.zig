//! Must not compile: claims that are not a struct.
const jwt = @import("security").jwt;

const Claims = u32;

test {
    comptime jwt.assertClaims(Claims);
}
