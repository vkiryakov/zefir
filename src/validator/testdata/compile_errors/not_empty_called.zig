const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.notEmpty() };
};

test {
    comptime v.assertRules(Bad);
}
