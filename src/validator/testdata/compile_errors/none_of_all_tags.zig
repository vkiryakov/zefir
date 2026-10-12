const v = @import("validator");

const Role = enum { admin, user, guest };

const Bad = struct {
    x: Role,
    pub const field_rules = .{ .x = v.noneOf(.{ .admin, .user, .guest }) };
};

test {
    comptime v.assertRules(Bad);
}
