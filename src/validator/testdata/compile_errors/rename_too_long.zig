const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.rename(&@as([65]u8, @splat('a'))) };
};

test {
    comptime v.assertRules(Bad);
}
