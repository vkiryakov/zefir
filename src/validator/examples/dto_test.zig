const std = @import("std");
const v = @import("validator");

pub const Role = enum { admin, editor, viewer };

pub const CreateUserRequest = struct {
    name: []const u8,
    age: u8,
    roles: []const Role,
    nickname: ?[]const u8 = null,

    pub const field_rules = .{
        .name = v.notEmpty,
        .age = v.positive,
        .roles = v.notEmpty,
        .nickname = v.notEmpty,
    };
};

test "every DTO of this file passes v.assertRules" {
    inline for (comptime std.meta.declarations(@This())) |name| {
        const decl = @field(@This(), name);
        if (@TypeOf(decl) == type) comptime v.assertRules(decl);
    }
}

test "CreateUserRequest rejects an empty name" {
    var path_buf: [256]u8 = undefined;
    const bad: CreateUserRequest = .{ .name = "", .age = 30, .roles = &.{.admin} };
    const violation = v.check(&bad, &path_buf) orelse return error.NoViolation;
    try std.testing.expectEqualStrings("validation.not_empty", violation.code);
    try std.testing.expectEqualStrings("name", violation.field.?);
}
