const v = @import("validator");

const Bad = struct {
    x: [22]u8,
    pub const field_rules = .{ .x = v.base64Url };
};

test {
    comptime v.assertRules(Bad);
}
