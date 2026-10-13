const v = @import("validator");

const Bad = struct {
    x: []const []const u32,
    pub const field_rules = .{ .x = v.each(.{ v.uniqueItems, v.maxItems(5) }) };
};

test {
    comptime v.assertRules(Bad);
}
