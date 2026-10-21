//! Must not compile: a claim of a type that JSON does not give.
const jwt = @import("jwt");

const Claims = struct {
    codes: [3]u8,
};

test {
    comptime jwt.assertClaims(Claims);
}
