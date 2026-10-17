const v = @import("validator");

const Bad = struct {
    x: []const u8,
    y: []const u8,
    pub const field_rules = .{ .x = v.rename("key"), .y = v.rename("key") };
};

test {
    _ = v.nameOf(Bad, .x);
}
