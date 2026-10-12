const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = .{ v.each(v.notEmpty), v.each(v.notEmpty) } };
};

test {
    comptime v.assertRules(Bad);
}
