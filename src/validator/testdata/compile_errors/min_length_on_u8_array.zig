const v = @import("validator");

const Bad = struct {
    x: [4]u8,
    pub const field_rules = .{ .x = v.minLength(3) };
};

test {
    comptime v.assertRules(Bad);
}
