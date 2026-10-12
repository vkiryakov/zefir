const v = @import("validator");

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.divisibleBy(5).withMessage("must be a multiple of {n}") };
};

test {
    comptime v.assertRules(Bad);
}
