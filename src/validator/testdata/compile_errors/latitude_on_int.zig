const v = @import("validator");

const Bad = struct {
    x: i32,
    pub const field_rules = .{ .x = v.latitude };
};

test {
    comptime v.assertRules(Bad);
}
