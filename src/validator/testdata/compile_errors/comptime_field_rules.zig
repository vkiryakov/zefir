const v = @import("validator");

const Bad = struct {
    comptime x: u32 = 1,
    pub const field_rules = .{ .x = v.positive };
};

test {
    comptime v.assertRules(Bad);
}
