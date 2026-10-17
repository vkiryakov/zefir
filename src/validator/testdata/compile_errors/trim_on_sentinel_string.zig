const v = @import("validator");

const Bad = struct {
    x: ?[:0]const u8,
    pub const field_rules = .{ .x = v.trimEnd };
};

test {
    comptime v.assertRules(Bad);
}
