//! README.md shows every example of the guide of rpc-nats as it is, and no
//! Zig code that is not a part of them. The examples need NATS servers:
//! tests/rpc-nats builds and runs them, and checks that README.md shows
//! their runs as they printed; this test needs no servers. The tutorial,
//! writing-a-transport.md, shows no Zig code that is not a part of the
//! sources of rpc-nats.

const check = @import("guide-check");
const options = @import("readme_options");

const guide = @embedFile("README.md");
const tutorial = @embedFile("writing-a-transport.md");

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

/// The files of src/rpc-nats/, which build.zig hands to this test under
/// their names: a test embeds no file outside the directory of its module.
/// A new file of src/rpc-nats/ goes into `rpc_nats_sources` of build.zig
/// too, or the tutorial cannot show it.
const sources = files: {
    var files: [options.sources.len][]const u8 = undefined;
    for (options.sources, &files) |name, *file| file.* = @embedFile(name);
    break :files files;
};

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, &example_files);
}

test "every Zig block of writing-a-transport.md is a part of the sources of rpc-nats" {
    try check.expectZigFrom("writing-a-transport.md", tutorial, &sources, "a file of src/rpc-nats/ that rpc_nats_sources of build.zig lists");
}
