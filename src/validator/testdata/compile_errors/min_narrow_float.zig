const v = @import("validator");

const min_rate: f32 = 0.1;

const Bad = struct {
    x: f64,
    pub const field_rules = .{ .x = v.min(min_rate) };
};

test {
    comptime v.assertRules(Bad);
}
