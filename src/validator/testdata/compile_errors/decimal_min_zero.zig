const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.decimal(.{ .min_decimal_digits = 0 }) };
};

test {
    comptime v.assertRules(Bad);
}
