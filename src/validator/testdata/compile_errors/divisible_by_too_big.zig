const v = @import("validator");

const Bad = struct {
    x: u8,
    pub const field_rules = .{ .x = v.divisibleBy(1000) };
};

test {
    comptime v.assertRules(Bad);
}
