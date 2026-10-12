const v = @import("validator");

const Bad = struct {
    x: [1]u32,
    pub const field_rules = .{ .x = v.uniqueItems };
};

test {
    comptime v.assertRules(Bad);
}
