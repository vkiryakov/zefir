const v = @import("validator");

const Bad = struct {
    x: [3]u32,
    pub const field_rules = .{ .x = v.minItems(1) };
};

test {
    comptime v.assertRules(Bad);
}
