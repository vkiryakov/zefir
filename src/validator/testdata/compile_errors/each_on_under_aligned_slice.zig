const v = @import("validator");

const Bad = struct {
    x: []align(1) const u32,
    pub const field_rules = .{ .x = v.each(v.positive) };
};

test {
    comptime v.assertRules(Bad);
}
