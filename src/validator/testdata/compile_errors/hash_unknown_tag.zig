const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.hash(.sha3_256) };
};

test {
    comptime v.assertRules(Bad);
}
