const v = @import("validator");

const Bad = struct {
    x: u2000,
    pub const field_rules = .{ .x = v.min(1 << 1700) };
};

test {
    comptime v.assertRules(Bad);
}
