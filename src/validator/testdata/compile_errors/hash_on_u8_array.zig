const v = @import("validator");

const Bad = struct {
    x: [32]u8,
    pub const field_rules = .{ .x = v.hash(.sha256) };
};

test {
    comptime v.assertRules(Bad);
}
