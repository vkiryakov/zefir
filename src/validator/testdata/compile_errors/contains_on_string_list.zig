const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.contains("@") };
};

test {
    comptime v.assertRules(Bad);
}
