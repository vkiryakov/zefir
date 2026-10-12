const v = @import("validator");

const Bad = struct {
    x: i32,
    pub const field_rules = .{ .x = v.negative.withMessage("{value} must be negative") };
};

test {
    comptime v.assertRules(Bad);
}
