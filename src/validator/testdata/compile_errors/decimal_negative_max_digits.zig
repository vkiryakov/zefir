const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.decimal(.{ .max_decimal_digits = -1 }) };
};

test {
    comptime v.assertRules(Bad);
}
