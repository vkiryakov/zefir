const v = @import("validator");

const name_rules = .{ v.notEmpty, v.notEmpty };

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ name_rules, v.notEmpty } };
};

test {
    comptime v.assertRules(Bad);
}
