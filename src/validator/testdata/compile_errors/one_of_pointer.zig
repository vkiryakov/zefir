const v = @import("validator");

const allowed = [_][]const u8{ "a", "b" };

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.oneOf(&allowed) };
};

test {
    comptime v.assertRules(Bad);
}
