//! README.md shows every compiled example of this directory verbatim, and
//! the output of every example program: an example that changes without its
//! copy in README.md fails this test.

const std = @import("std");
const cases = @import("cases");

const readme = @embedFile("README.md");

/// Fails unless README.md contains `block`. Both are compared with "\r\n"
/// turned into "\n", since Git may check files out with CRLF on Windows.
fn expectInReadme(block: []const u8) !void {
    const gpa = std.testing.allocator;
    const doc = try std.mem.replaceOwned(u8, gpa, readme, "\r\n", "\n");
    defer gpa.free(doc);
    const wanted = try std.mem.replaceOwned(u8, gpa, block, "\r\n", "\n");
    defer gpa.free(wanted);
    if (std.mem.find(u8, doc, wanted) == null) {
        std.debug.print("README.md does not contain this block:\n{s}\n", .{wanted});
        return error.TestBlockNotInReadme;
    }
}

test "README.md shows every example file verbatim" {
    inline for (cases.examples) |example| {
        try expectInReadme("```zig\n" ++ @embedFile(example.name ++ ".zig") ++ "```\n");
    }
}

test "README.md shows what every example program prints" {
    inline for (cases.examples) |example| {
        if (example.stdout) |stdout| try expectInReadme("```text\n" ++ stdout ++ "```\n");
    }
}
