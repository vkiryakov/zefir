const v = @import("validator");

const Bad = struct {
    @"items[0]": u32,
    x: u32,
    pub const field_rules = .{ .x = v.positive };
};

test {
    comptime v.assertRules(Bad);
}
