const v = @import("validator");

const Shape = union(enum) {
    circle: f32,
    pub const field_rules = .{ .circle = v.positive };
};

const Bad = struct {
    x: Shape,
};

test {
    comptime v.assertRules(Bad);
}
