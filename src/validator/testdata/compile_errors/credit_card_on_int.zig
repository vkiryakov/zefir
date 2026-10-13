const v = @import("validator");

const Bad = struct {
    x: u64,
    pub const field_rules = .{ .x = v.creditCard };
};

test {
    comptime v.assertRules(Bad);
}
