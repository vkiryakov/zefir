const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.decimal(.{ .decimal_digits = "1,2" }) };
};

test {
    comptime v.assertRules(Bad);
}
