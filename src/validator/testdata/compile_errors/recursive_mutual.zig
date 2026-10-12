const v = @import("validator");

const Bad = struct {
    tag: u32,
    x: []const Child = &.{},
    pub const field_rules = .{ .tag = v.positive };
};

const Child = struct {
    x: []const Bad = &.{},
};

test {
    comptime v.assertRules(Bad);
}
