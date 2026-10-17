const v = @import("validator");

const Bad = struct {
    x: u8,
    pub const field_rules = .{ .x = v.trim };
};

test {
    comptime v.assertRules(Bad);
}
