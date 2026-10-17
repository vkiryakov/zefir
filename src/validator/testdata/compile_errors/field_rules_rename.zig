const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = v.rename("userName");
};

test {
    comptime v.assertRules(Bad);
}
