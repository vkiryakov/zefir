const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = 5;
};

test {
    comptime v.assertRules(Bad);
}
