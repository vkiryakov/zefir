//! README.md of the transport's package shows parts of this application
//! and of the transport as they are, and the report of the conformance
//! suite on the mailbox as the suite writes it: a file that changes
//! without its copy in README.md fails this test. build.zig hands README.md,
//! the application's build.zig and the transport's src/root.zig to it as
//! anonymous imports, and the checks of the guides of rpc as `guide-check`.

const std = @import("std");
const rpc = @import("zefir-rpc");
const mailbox = @import("rpc-mailbox");
const check = @import("guide-check");

const testing = std.testing;

const readme = @embedFile("README.md");

test "every Zig block of README.md is a part of the application or of the transport" {
    try check.expectZigFrom("README.md", readme, &.{
        @embedFile("build.zig"),
        @embedFile("conformance_test.zig"),
        @embedFile("root.zig"),
    }, "consumer/build.zig, consumer/src/conformance_test.zig or src/root.zig");
}

test "README.md shows the report of the conformance suite on the mailbox as it is" {
    var harness: mailbox.testing.Harness = .{};
    var report = try rpc.testing.conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&report});
    defer testing.allocator.free(text);
    // A note that only a slow machine gets, such as that of T18 when an
    // answer came after its start returned, may be missing from README.md;
    // the notes it shows must be in the report, in their places.
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  note ") and std.mem.find(u8, readme, line) == null) continue;
        try shown.appendSlice(testing.allocator, line);
        try shown.append(testing.allocator, '\n');
    }
    try check.expectFile("README.md", readme, "text", shown.items);
}
