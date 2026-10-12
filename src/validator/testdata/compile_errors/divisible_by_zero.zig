const v = @import("validator");

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.divisibleBy(0) };
};

test {
    comptime v.assertRules(Bad);
}
