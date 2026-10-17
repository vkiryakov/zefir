const std = @import("std");
const v = @import("validator");

fn normalizePhone(_: std.mem.Allocator, phone: []const u8) error{BadPhone}![]const u8 {
    if (phone.len == 0) return error.BadPhone;
    return phone;
}

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.trim, normalizePhone } };
};

test {
    comptime v.assertRules(Bad);
}
