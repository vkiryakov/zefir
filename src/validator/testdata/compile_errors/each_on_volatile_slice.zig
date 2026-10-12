const v = @import("validator");

const Bad = struct {
    x: []volatile u32,
    pub const field_rules = .{ .x = v.each(v.positive) };
};

test {
    comptime v.assertRules(Bad);
}
