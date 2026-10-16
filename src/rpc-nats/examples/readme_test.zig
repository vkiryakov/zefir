//! README.md shows every example of the guide of rpc-nats as it is, and no
//! Zig code that is not a part of them. The examples need NATS servers:
//! tests/rpc-nats builds and runs them, and checks that README.md shows
//! their runs as they printed; this test needs no servers.

const check = @import("guide-check");

const guide = @embedFile("README.md");

/// The examples, as tests/rpc-nats/build.zig runs them.
const examples = [_][]const u8{ "getting_started", "two_services" };

const example_files = files: {
    var files: [examples.len][]const u8 = undefined;
    for (examples, &files) |name, *file| file.* = @embedFile(name ++ ".zig");
    break :files files;
};

test "README.md shows every example as it is" {
    inline for (examples) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, &example_files);
}
