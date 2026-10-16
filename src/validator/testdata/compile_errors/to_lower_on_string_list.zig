const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = .{ v.toLower, v.maxItems(5) } };
};

test {
    comptime v.assertRules(Bad);
}
