const std = @import("std");
const v = @import("validator");

fn normalizeTag(_: std.mem.Allocator, tag: []const u8) []const u8 {
    return tag;
}

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.each(normalizeTag) };
};

test {
    comptime v.assertRules(Bad);
}
