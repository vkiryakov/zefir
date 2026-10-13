const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.minDate("2021-01-01"), v.maxDate("2020-12-31") } };
};

test {
    comptime v.assertRules(Bad);
}
