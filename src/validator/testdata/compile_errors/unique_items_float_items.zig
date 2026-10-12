const v = @import("validator");

const Bad = struct {
    x: []const f64,
    pub const field_rules = .{ .x = .{ v.maxItems(10), v.uniqueItems } };
};

test {
    comptime v.assertRules(Bad);
}
