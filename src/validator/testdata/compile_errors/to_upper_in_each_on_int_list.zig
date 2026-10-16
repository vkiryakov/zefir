const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.each(.{ v.toUpper, v.positive }) };
};

test {
    comptime v.assertRules(Bad);
}
