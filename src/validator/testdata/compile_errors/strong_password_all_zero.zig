const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.strongPassword(.{ .min_length = 0, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }) };
};

test {
    comptime v.assertRules(Bad);
}
