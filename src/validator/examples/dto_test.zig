const std = @import("std");
const v = @import("validator");

pub const Role = enum { admin, editor, viewer };

pub const CreateUserRequest = struct {
    email: []const u8,
    name: []const u8,
    birthday: []const u8,
    roles: []const Role,
    team_id: ?u32 = null,

    pub const field_rules = .{
        .email = v.email,
        .name = .{ v.notBlank, v.maxLength(64) },
        .birthday = v.minDate("1900-01-01"),
        .roles = .{ v.notEmpty, v.uniqueItems },
        .team_id = v.positive,
    };
};

test "every DTO of this file passes v.assertRules" {
    comptime v.assertRules(@This()); // the file itself: a DTO when it has top-level fields
    inline for (comptime std.meta.declarations(@This())) |name| {
        const decl = @field(@This(), name);
        if (@TypeOf(decl) == type) comptime v.assertRules(decl);
    }
}

test "CreateUserRequest rejects an invalid email" {
    var path_buf: [256]u8 = undefined;
    const bad: CreateUserRequest = .{ .email = "ada.example.com", .name = "Ada", .birthday = "1990-12-10", .roles = &.{.admin} };
    const violation = v.check(&bad, &path_buf) orelse return error.NoViolation;
    try std.testing.expectEqualStrings("validation.email", violation.code);
    try std.testing.expectEqualStrings("email", violation.field.?);
}
