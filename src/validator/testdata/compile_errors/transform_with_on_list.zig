const std = @import("std");
const v = @import("validator");

fn normalizeTag(_: std.mem.Allocator, tag: []const u8) error{TooLong}![]const u8 {
    if (tag.len > 32) return error.TooLong;
    return tag;
}

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.transformWith(normalizeTag) };
};

test {
    comptime v.assertRules(Bad);
}
