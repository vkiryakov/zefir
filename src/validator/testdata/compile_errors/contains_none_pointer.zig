const v = @import("validator");

const forbidden = [_][]const u8{ "a", "b" };
const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.containsNone(&forbidden) };
};

test {
    comptime v.assertRules(Bad);
}
