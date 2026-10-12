const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.minLength(10), v.maxLength(5) } };
};

test {
    comptime v.assertRules(Bad);
}
