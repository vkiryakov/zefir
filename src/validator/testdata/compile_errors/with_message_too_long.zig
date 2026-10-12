const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.maxItems(5).withMessage(&@as([513]u8, @splat('m'))) };
};

test {
    comptime v.assertRules(Bad);
}
