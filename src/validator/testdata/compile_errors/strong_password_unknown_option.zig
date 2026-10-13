const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.strongPassword(.{ .min_lenght = 8 }) };
};

test {
    comptime v.assertRules(Bad);
}
