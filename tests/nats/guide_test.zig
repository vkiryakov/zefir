//! The guide of zefir-nats, src/nats/examples/README.md, and "nats in a
//! minute" of the repository's README.md, against what their programs
//! printed in this build, on the servers of the repository's
//! docker-compose.yml. The build embeds the guide as `guide`, the
//! repository's README.md as `root_readme`, each program as
//! `<program>.zig` and what each run printed as `<name>.out`. `zig build
//! test-nats` in the repository checks the rest of both.

const std = @import("std");
const check = @import("guide-check");
const cases = @import("cases");
const runs = @import("guide_runs");

test "the guide and README.md of the repository show every run as it printed, after its program" {
    inline for (runs.programs, runs.names, runs.commands, runs.docs) |program, name, command, doc| {
        const shown_in = if (comptime std.mem.eql(u8, doc, "guide")) "src/nats/examples/README.md" else "README.md of the repository";
        try check.expectRun(shown_in, @embedFile(doc), @embedFile(program ++ ".zig"), command, @embedFile(name ++ ".out"));
    }
}

test "this build runs every program whose runs the guide and README.md of the repository show" {
    for (cases.server_programs) |program| try std.testing.expect(runsOf(program, "guide"));
    for (cases.root_readme) |program| try std.testing.expect(runsOf(program, "root_readme"));
}

/// Whether this build runs `program` for the document `doc`.
fn runsOf(program: []const u8, doc: []const u8) bool {
    for (runs.programs, runs.docs) |run_program, run_doc| {
        if (std.mem.eql(u8, run_program, program) and std.mem.eql(u8, run_doc, doc)) return true;
    }
    return false;
}
