const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.minDate };
};

test {
    comptime v.assertRules(Bad);
}
