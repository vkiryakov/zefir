const std = @import("std");
const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = v.trim };
};

test {
    var value: Bad = .{ .x = " a " };
    _ = &value;
    try v.transform(std.testing.allocator, value);
}
