const std = @import("std");
const v = @import("validator");

fn keep(_: std.mem.Allocator, value: anytype) @TypeOf(value) {
    return value;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.transformWith(keep) };
};

test {
    comptime v.assertRules(Bad);
}
