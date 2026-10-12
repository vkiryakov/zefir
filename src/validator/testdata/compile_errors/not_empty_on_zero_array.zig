const v = @import("validator");

const Bad = struct {
    x: [0]u32,
    pub const field_rules = .{ .x = v.notEmpty };
};

test {
    comptime v.assertRules(Bad);
}
