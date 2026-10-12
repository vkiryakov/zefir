const std = @import("std");
const v = @import("validator");

const Bad = struct {
    x: f64,
    pub const field_rules = .{ .x = v.max(std.math.nan(f64)) };
};

test {
    comptime v.assertRules(Bad);
}
