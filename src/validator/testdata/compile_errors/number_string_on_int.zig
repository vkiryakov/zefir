const v = @import("validator");

const Bad = struct {
    x: ?u32,
    pub const field_rules = .{ .x = v.numberString };
};

test {
    comptime v.assertRules(Bad);
}
