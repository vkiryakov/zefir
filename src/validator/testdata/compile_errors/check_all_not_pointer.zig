const std = @import("std");
const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

test {
    const report = try v.checkAll(std.testing.allocator, Item{ .name = "" });
    report.deinit();
}
