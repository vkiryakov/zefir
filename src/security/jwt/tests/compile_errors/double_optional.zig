//! Must not compile: an optional of an optional, which null cannot tell
//! apart.
const jwt = @import("security").jwt;

const Claims = struct {
    level: ??u8 = null,
};

test {
    comptime jwt.assertClaims(Claims);
}
