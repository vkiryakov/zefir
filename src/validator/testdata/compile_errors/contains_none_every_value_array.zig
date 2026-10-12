const v = @import("validator");

const Bad = struct {
    x: [2]bool,
    pub const field_rules = .{ .x = v.containsNone(.{ true, false }) };
};

test {
    comptime v.assertRules(Bad);
}
