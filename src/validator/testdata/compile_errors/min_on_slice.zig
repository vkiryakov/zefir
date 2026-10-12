const v = @import("validator");

const Bad = struct {
    x: []const i32,
    pub const field_rules = .{ .x = v.min(0) };
};

test {
    comptime v.assertRules(Bad);
}
