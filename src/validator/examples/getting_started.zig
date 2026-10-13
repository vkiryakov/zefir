const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Role = enum { admin, editor, viewer };

const Address = struct {
    city: []const u8,
    zip: []const u8,

    pub const field_rules = .{
        .city = v.notBlank,
        .zip = .{ v.length(5, 5), v.digits },
    };
};

const SignUp = struct {
    email: []const u8,
    age: u8,
    roles: []const Role,
    address: Address, // no entry below: Address declares the rules of its fields
    referrer_id: ?u64 = null,

    pub const field_rules = .{
        .email = v.email, // one rule
        .age = v.range(18, 120),
        .roles = .{ v.notEmpty, v.uniqueItems }, // a tuple: its rules run in order
        .referrer_id = v.positive, // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service" },
        .format = .text,
    });
    defer logger.deinit();

    const request: SignUp = .{
        .email = "ada@example.com",
        .age = 36,
        .roles = &.{.editor},
        .address = .{ .city = "Springfield", .zip = "6270" },
    };

    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        logger.warn("Invalid sign-up", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    } else {
        logger.info("Sign-up accepted", .{});
    }
}
