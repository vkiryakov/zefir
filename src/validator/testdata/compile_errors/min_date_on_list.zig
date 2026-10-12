const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.minDate("2020-01-01") };
};

test {
    comptime v.assertRules(Bad);
}
