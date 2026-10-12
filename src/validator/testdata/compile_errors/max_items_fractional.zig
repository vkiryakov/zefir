const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.maxItems(1.5) };
};

test {
    comptime v.assertRules(Bad);
}
