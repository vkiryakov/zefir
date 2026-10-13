const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.minDate("0000-01-01") };
};

test {
    comptime v.assertRules(Bad);
}
