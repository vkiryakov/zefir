const v = @import("validator");

var text: []const u8 = "must not be empty";

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.notEmpty.withMessage(text) };
};

test {
    comptime v.assertRules(Bad);
}
