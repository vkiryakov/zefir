const v = @import("validator");

const Bad = struct {
    x: []const u8,
    pub const field_rules = .{ .x = .{ v.trim, v.rename("userName") } };
};

test {
    _ = v.fieldNamed(Bad, "userName");
}
