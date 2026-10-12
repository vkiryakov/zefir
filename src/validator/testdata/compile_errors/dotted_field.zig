const v = @import("validator");

const Bad = struct {
    @"a.b": u32,
    pub const field_rules = .{ .@"a.b" = v.positive };
};

test {
    comptime v.assertRules(Bad);
}
