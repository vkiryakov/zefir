const v = @import("validator");

const Bad = struct {
    userName: []const u8,
    x: []const u8,
    pub const field_rules = .{ .x = v.rename("userName") };
};

test {
    comptime v.assertRules(Bad);
}
