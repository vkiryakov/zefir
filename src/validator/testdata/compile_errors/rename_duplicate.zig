const v = @import("validator");

const Bad = struct {
    x: []const u8,
    login: []const u8,
    pub const field_rules = .{
        .x = v.rename("userName"),
        .login = .{ v.rename("userName"), v.notBlank },
    };
};

test {
    comptime v.assertRules(Bad);
}
