const std = @import("std");
const v = @import("validator");

const Role = enum { admin, editor, viewer };

// A rule with a message is a value: declare it once, use it on any field.
const filled = v.notEmpty.withMessage("please fill in this field");

const Profile = struct {
    name: []const u8,
    nickname: []const u8,
    age: u8,
    role: Role,
    tags: []const []const u8,
    height: f64,
    weight: f64,

    pub const field_rules = .{
        .name = filled,
        .nickname = filled,
        .age = v.range(18, 120).withMessage("age must be from {min} to {max}"),
        .role = v.oneOf(.{ .admin, .editor }).withMessage("role must be one of: {values}"),
        .tags = v.maxItems(2).withMessage("at most {max} tags"),
        .height = v.positive.withMessage("height must be above zero"), // NaN keeps validation.finite
        .weight = .{ v.finite.withMessage("weight must be a number"), v.positive },
    };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const profile: Profile = .{
        .name = "",
        .nickname = "ada",
        .age = 17,
        .role = .viewer,
        .tags = &.{ "a", "b", "c" },
        .height = std.math.nan(f64),
        .weight = std.math.nan(f64),
    };

    const report = try v.checkAll(init.gpa, &profile);
    defer report.deinit();
    for (report.violations) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    }
}
