const v = @import("validator");

const Bad = struct {
    name: []const u8,
    x: []const Bad = &.{},
    pub const field_rules = .{ .name = v.notEmpty };
};

test {
    comptime v.assertRules(Bad);
}
