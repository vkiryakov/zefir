const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.minDate("2020-02-30") };
};

test {
    comptime v.assertRules(Bad);
}
