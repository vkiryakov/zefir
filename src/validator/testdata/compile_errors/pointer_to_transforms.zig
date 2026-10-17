const v = @import("validator");

const Profile = struct {
    name: []const u8,
    pub const field_rules = .{ .name = .{ v.rename("displayName"), v.trim } };
};

const Bad = struct {
    x: *const Profile,
};

test {
    comptime v.assertRules(Bad);
}
