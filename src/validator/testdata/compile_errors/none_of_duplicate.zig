const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.noneOf(.{ "root", "admin", "root" }) };
};

test {
    comptime v.assertRules(Bad);
}
