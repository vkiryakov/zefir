const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.minDate(1577836800) };
};

test {
    comptime v.assertRules(Bad);
}
