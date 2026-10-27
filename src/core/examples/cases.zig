//! The examples of README.md, the guide of zefir-core. build.zig builds and
//! runs the programs and the tests; readme_test.zig checks that README.md
//! shows every file as it is and every run as it printed.

/// A program of the guide: it needs nothing but core, and prints the same
/// in every run.
pub const Program = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// Where it prints what README.md shows as its run: std.log writes to
    /// stderr.
    output: Output = .stdout,

    pub const Output = enum { stdout, stderr };
};

/// The programs: `zig build test-core` runs them.
pub const programs = [_]Program{
    .{ .name = "minute", .output = .stderr },
    .{ .name = "http_handler" },
    .{ .name = "rpc_handler" },
    .{ .name = "services" },
};

/// The other files README.md shows as they are: the tests.
pub const files = [_][]const u8{ "context_test", "trace_test" };

/// The tests among `files`: `zig build test-core` runs them.
pub const tests = [_][]const u8{ "context_test", "trace_test" };

/// The programs that README.md at the root of the repository shows too, as
/// they are and with a run of each: its "core in a minute".
pub const root_readme = [_][]const u8{"minute"};

/// The command README.md shows for a run of `program`: the programs read
/// no settings.
pub fn command(comptime program: Program) []const u8 {
    _ = program;
    return "$ zig build run";
}
