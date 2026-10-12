const v = @import("validator");

const Bad = struct {
    name: []const u8,
    pub const field_rules = .{ .zzz = v.notEmpty };
};

test {
    comptime v.assertRules(Bad);
}
