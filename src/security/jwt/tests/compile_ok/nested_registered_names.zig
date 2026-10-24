//! Must compile: the names of registered claims are ordinary inside a
//! nested struct.
const jwt = @import("security").jwt;

const Grant = struct {
    exp: i64,
    aud: []const u8,
    scopes: []const []const u8 = &.{},
};

const Claims = struct {
    grant: Grant,
    grants: []const Grant = &.{},
};

test {
    comptime jwt.assertClaims(Claims);
}
