const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.minDate("2020-01-01T00:00:00+01:00"), v.maxDate("2019-12-31T22:59:59Z") } };
};

test {
    comptime v.assertRules(Bad);
}
