const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.each(.{ v.rename("tag"), v.trim, v.notBlank }) };
};

test {
    comptime v.assertRules(Bad);
}
