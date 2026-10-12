const v = @import("validator");

const Bad = struct {
    x: u8,
    pub const field_rules = .{ .x = v.oneOf(.{ 1, 300 }) };
};

test {
    comptime v.assertRules(Bad);
}
