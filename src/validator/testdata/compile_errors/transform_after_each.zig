const v = @import("validator");

fn dedupe(_: @import("std").mem.Allocator, tags: []const []const u8) []const []const u8 {
    return tags;
}

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = .{ v.maxItems(10), v.each(v.trim), v.transformWith(dedupe) } };
};

test {
    comptime v.assertRules(Bad);
}
