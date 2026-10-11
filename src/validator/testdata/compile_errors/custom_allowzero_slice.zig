const v = @import("validator");

fn f(x: []const u8) bool {
    return x.len > 0;
}

const Bad = struct {
    x: []allowzero const u8,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
