const v = @import("validator");

const User = struct {
    email: []const u8,
    pub const field_rules = .{ .email = v.notEmpty };
};

test {
    var path_buf: [64]u8 = undefined;
    const users: []const User = &.{};
    _ = v.check(users, &path_buf);
}
