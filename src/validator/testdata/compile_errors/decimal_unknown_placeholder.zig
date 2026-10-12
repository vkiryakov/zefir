const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.decimal(.{}).withMessage("at most {max_decimal_digits} places") };
};

test {
    comptime v.assertRules(Bad);
}
