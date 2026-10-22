//! Must not compile: a rule that does not fit its claim; the error is the
//! validator's own.
const jwt = @import("jwt");
const v = @import("validator");

const Claims = struct {
    count: u64,

    pub const field_rules = .{ .count = v.maxLength(10) };
};

test {
    comptime jwt.assertClaims(Claims);
}
