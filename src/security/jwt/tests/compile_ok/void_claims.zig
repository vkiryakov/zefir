//! Must compile: void claims, for an application that the registered
//! claims are enough for.
const jwt = @import("jwt");

test {
    comptime jwt.assertClaims(void);
}
