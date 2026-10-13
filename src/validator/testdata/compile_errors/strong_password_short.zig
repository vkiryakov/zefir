const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.strongPassword(.{ .min_length = 3 }) };
};

test {
    comptime v.assertRules(Bad);
}
