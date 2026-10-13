const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const validate = .{ .x = v.notEmpty };
};

test {
    comptime v.assertRules(Bad);
}
