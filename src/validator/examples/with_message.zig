const std = @import("std");
const log = @import("log");
const v = @import("validator");

const Role = enum { admin, editor, viewer };
const Language = enum { en, de, fr, ja };

// A rule with a message is a value: declare it once, use it on any field.
const filled = v.notEmpty.withMessage("please fill in this field");

const Profile = struct {
    name: []const u8,
    nickname: []const u8,
    age: u8,
    role: Role,
    languages: []const Language,
    website: ?[]const u8 = null,
    height: f64,
    weight: f64,

    pub const field_rules = .{
        .name = filled,
        .nickname = filled,
        .age = v.range(18, 120).withMessage("age must be from {min} to {max}"),
        .role = v.oneOf(.{ .admin, .editor }).withMessage("role must be one of: {values}"),
        .languages = v.maxItems(2).withMessage("at most {max} languages"),
        .website = v.httpUrl.withMessage("website must be a link such as https://example.com"),
        .height = v.positive.withMessage("height must be above zero"), // NaN keeps validation.finite
        .weight = .{ v.finite.withMessage("weight must be a number"), v.positive },
    };
};

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "profile-service" },
        .format = .text,
    });
    defer logger.deinit();

    const profile: Profile = .{
        .name = "",
        .nickname = "ada",
        .age = 17,
        .role = .viewer,
        .languages = &.{ .en, .fr, .de },
        .website = "example.com",
        .height = std.math.nan(f64),
        .weight = std.math.nan(f64),
    };

    const report = try v.checkAll(init.gpa, &profile);
    defer report.deinit();
    for (report.violations) |violation| {
        logger.warn("Invalid profile", .{ .field = violation.field, .code = violation.code, .reason = violation.message });
    }
}
