const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.rename("userName"), v.notBlank, v.trim } };
};

test {
    comptime v.assertRules(Bad);
}
