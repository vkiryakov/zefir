const v = @import("validator");

const Bad = struct {
    x: [3]u32,
    pub const field_rules = .{ .x = v.empty };
};

test {
    comptime v.assertRules(Bad);
}
