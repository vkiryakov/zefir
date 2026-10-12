const v = @import("validator");

const Role = enum { admin, user, guest };
const Color = enum { red, admin };
const Bad = struct {
    x: []const Role,
    pub const field_rules = .{ .x = v.containsNone(.{Color.red}) };
};

test {
    comptime v.assertRules(Bad);
}
