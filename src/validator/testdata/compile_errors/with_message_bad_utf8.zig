const v = @import("validator");

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.min(1).withMessage("\xc3") };
};

test {
    comptime v.assertRules(Bad);
}
