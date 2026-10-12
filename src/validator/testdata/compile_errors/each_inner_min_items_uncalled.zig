const v = @import("validator");

const Bad = struct {
    x: []const []const u32,
    pub const field_rules = .{ .x = v.each(v.minItems) };
};

test {
    comptime v.assertRules(Bad);
}
