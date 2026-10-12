const v = @import("validator");

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.length(3, 32) };
};

test {
    comptime v.assertRules(Bad);
}
