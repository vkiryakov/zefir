const v = @import("validator");

const Bad = struct {
    x: i32,
    pub const field_rules = .{ .x = .{ v.min(10), v.max(5) } };
};

test {
    comptime v.assertRules(Bad);
}
