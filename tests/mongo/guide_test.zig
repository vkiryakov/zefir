//! The guide of zefir-mongo, src/mongo/examples/README.md, against what
//! its programs printed in this build, on the servers of the repository's
//! docker-compose.yml. The build embeds the guide as `guide`, each program
//! as `<name>.zig` and what it printed as `<name>.out`. `zig build
//! test-mongo` in the repository checks the rest of the guide.

const std = @import("std");
const check = @import("guide-check");
const cases = @import("cases");
const examples = @import("guide_examples");

const guide = @embedFile("guide");
const name = "src/mongo/examples/README.md";

test "the guide shows a run of every program as it printed, after the program" {
    inline for (examples.names, examples.commands) |example, command| {
        try check.expectRun(name, guide, @embedFile(example ++ ".zig"), command, @embedFile(example ++ ".out"));
    }
}

test "this build runs every program of the guide that needs mongod" {
    try std.testing.expectEqual(cases.server_programs.len, examples.names.len);
    for (cases.server_programs, examples.names) |listed, run| try std.testing.expectEqualStrings(listed, run);
}
