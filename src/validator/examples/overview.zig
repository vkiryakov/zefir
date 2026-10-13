const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Role = enum { admin, editor, viewer };

const SignUp = struct {
    email: []const u8,
    age: u8,
    roles: []const Role,
    nickname: ?[]const u8 = null,

    // The rules of the fields. The validator finds them by this name, so the
    // struct must declare them as `pub const field_rules`.
    pub const field_rules = .{
        .email = v.email,
        .age = v.range(18, 120),
        .roles = .{ v.notEmpty, v.uniqueItems }, // a tuple: its rules run in order
        .nickname = v.length(3, 32), // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "signup-service" },
        .format = .text,
    });
    defer logger.deinit();

    // The value to check, for example a decoded request body.
    const request: SignUp = .{ .email = "ada@example.com", .age = 36, .roles = &.{ .editor, .editor } };

    // v.check allocates no memory, so it needs room from you to write the path
    // of the field that failed, such as "roles"; violation.field points into it.
    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        logger.warn("Invalid sign-up", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
