const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = .{ v.notEmpty, v.each } };
};

test {
    comptime v.assertRules(Bad);
}
