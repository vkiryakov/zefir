const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = .{ v.maxItems(1001), v.uniqueItems } };
};

test {
    comptime v.assertRules(Bad);
}
