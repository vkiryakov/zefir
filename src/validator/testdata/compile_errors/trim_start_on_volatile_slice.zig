const v = @import("validator");

const Bad = struct {
    x: []volatile u8,
    pub const field_rules = .{ .x = v.trimStart };
};

test {
    comptime v.assertRules(Bad);
}
