const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.rfc3339, v.minDate("2020-01-01") } };
};

test {
    comptime v.assertRules(Bad);
}
