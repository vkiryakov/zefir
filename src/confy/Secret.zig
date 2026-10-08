//! A string that is never printed: `{f}` writes `[redacted]`, `{s}` doesn't
//! compile, and `{any}` shows only an address and a length. Read the value
//! with `expose()`, so every place that uses it is easy to find.
//!
//! It guards against accidental logging, not against code that wants the
//! value: Zig has no private fields. `confy.free` wipes it before freeing.

const std = @import("std");

const Secret = @This();

// A many-item pointer instead of a slice: `{any}` can't print what it points to.
ptr: [*]const u8,
len: usize,

pub fn init(value: []const u8) Secret {
    return .{ .ptr = value.ptr, .len = value.len };
}

/// The secret itself. Don't log it.
pub fn expose(secret: Secret) []const u8 {
    return secret.ptr[0..secret.len];
}

pub fn format(_: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("[redacted]");
}

test "printing never shows the value" {
    const Config = struct { host: []const u8, password: Secret };
    const config: Config = .{ .host = "db", .password = .init("s3cret") };

    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{config.password});
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("[redacted]", formatted);

    const debug = try std.fmt.allocPrint(std.testing.allocator, "{any}", .{config});
    defer std.testing.allocator.free(debug);
    try std.testing.expect(std.mem.find(u8, debug, "s3cret") == null);
    try std.testing.expect(std.mem.find(u8, debug, "115, 51") == null); // "s3" as bytes

    try std.testing.expectEqualStrings("s3cret", config.password.expose());
}
