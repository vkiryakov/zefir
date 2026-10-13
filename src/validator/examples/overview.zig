const std = @import("std");
const v = @import("validator");

const SignUp = struct {
    name: []const u8,
    age: u8,
    tags: []const []const u8 = &.{},

    // The rules of the fields. The validator finds them by this name, so the
    // struct must declare them as `pub const field_rules`.
    pub const field_rules = .{
        .name = v.notEmpty,
        .age = v.positive,
        .tags = v.each(v.notEmpty), // every item of the list
    };
};

pub fn main() void {
    // The value to check, for example a decoded request body.
    const request: SignUp = .{ .name = "Ada", .age = 36, .tags = &.{ "admin", "" } };

    // v.check allocates no memory, so it needs room from you to write the path
    // of the field that failed, such as "tags[1]"; violation.field points into it.
    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        // Prints "tags[1]: must not be empty (validation.not_empty)".
        std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    }
}
