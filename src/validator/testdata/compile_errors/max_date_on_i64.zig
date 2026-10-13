const v = @import("validator");

const Bad = struct {
    x: i64,
    pub const field_rules = .{ .x = v.maxDate("2020-12-31T23:59:59Z") };
};

test {
    comptime v.assertRules(Bad);
}
