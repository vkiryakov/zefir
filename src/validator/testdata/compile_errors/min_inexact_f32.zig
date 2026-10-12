const v = @import("validator");

const Bad = struct {
    x: f32,
    pub const field_rules = .{ .x = v.min(16777217) };
};

test {
    comptime v.assertRules(Bad);
}
