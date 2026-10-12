const std = @import("std");
const v = @import("validator");

const SignUp = struct {
    name: []const u8,
    age: u8,
    tags: []const []const u8 = &.{},
    nickname: ?[]const u8 = null,

    pub const field_rules = .{
        .name = v.notEmpty, // one rule
        .age = v.positive,
        .tags = .{ v.notEmpty, v.each(v.notEmpty) }, // the list, then each item
        .nickname = v.notEmpty, // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const request: SignUp = .{ .name = "Ada", .age = 36, .tags = &.{ "admin", "" } };

    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    } else {
        try out.print("valid\n", .{});
    }
}
