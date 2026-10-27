//! Helpers of the tests of the guide: the files of a page written into a
//! temporary directory, and the problems of a load as `{f}` writes them.

const std = @import("std");
const confy = @import("confy");

const testing = std.testing;

/// Writes each of `files`, a path and its text, into `dir`, with the
/// directories on its path.
pub fn write(dir: std.Io.Dir, files: []const [2][]const u8) !void {
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try dir.createDirPath(testing.io, parent);
        try dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
}

/// Fails unless the problems in `diag` are `expected`, as `{f}` writes them.
pub fn expectProblems(expected: []const u8, diag: *const confy.Diagnostics) !void {
    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

/// Loads a `T` with `options`, which must fail with the problems `expected`.
pub fn expectLoadProblems(comptime T: type, options: confy.Options, expected: []const u8) !void {
    var diag: confy.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &diag;

    var config: T = undefined;
    try testing.expectError(error.InvalidConfig, confy.load(testing.allocator, &config, with_diagnostics));
    try expectProblems(expected, &diag);
}

/// `text` with `old` replaced by `new` once, as the guide edits a file of
/// its examples; owned by the caller, and an error unless `old` is there.
pub fn edit(text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const at = std.mem.find(u8, text, old) orelse return error.TestEditNotFound;
    return std.mem.concat(testing.allocator, u8, &.{ text[0..at], new, text[at + old.len ..] });
}
