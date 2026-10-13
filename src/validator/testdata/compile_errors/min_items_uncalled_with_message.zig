const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.minItems.withMessage("x") };
};

test {
    comptime v.assertRules(Bad);
}
