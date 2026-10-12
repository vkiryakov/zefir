const v = @import("validator");

const Role = enum { admin, user };

const Bad = struct {
    x: []const Role,
    pub const field_rules = .{ .x = v.notContains("admin") };
};

test {
    comptime v.assertRules(Bad);
}
