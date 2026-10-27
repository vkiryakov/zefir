//! The examples of README.md, the guide of zefir-log. build.zig builds and
//! runs the programs, compiles the one that posts to Slack and checks the
//! calls that must not compile; readme_test.zig checks that README.md
//! shows every file as it is, every run as it printed and every call that
//! does not compile with the error the build gives.

/// The programs: each is a whole `main` that logs with zefir-log. The
/// build runs each and keeps what it printed on stdout and on stderr.
pub const programs = [_][]const u8{
    "minute",
    "getting_started",
    "text_format",
    "levels",
    "service",
    "config",
    "stats",
    "emergency",
    "interceptor",
    "alerts",
};

/// Whole programs that the build only compiles: a run of slack posts to a
/// Slack webhook.
pub const compiled = [_][]const u8{"slack"};

/// The programs that README.md at the root of the repository shows too, as
/// they are and with a run of each: its "log in a minute".
pub const root_readme = [_][]const u8{"minute"};

/// The command README.md shows for a run of a program.
pub const command = "$ zig build run";

/// A call that must not compile: the test of compile_errors.zig that
/// holds it, the line README.md shows, and the error the build gives,
/// which README.md shows after "error: ".
pub const CompileError = struct {
    name: []const u8,
    line: []const u8,
    text: []const u8,
};

/// The calls that README.md shows the build refusing, in its order.
pub const compile_errors = [_]CompileError{
    .{
        .name = "a field without a name",
        .line = "logger.info(\"User created\", .{user_id}); // compile error: a field without a name",
        .text = "zefir.log: fields need names: write .{ .user_id = id }, not .{ id }",
    },
    .{
        .name = "an error union as a value",
        .line = "logger.info(\"Listening\", .{ .port = port }); // compile error: port is an anyerror!u16",
        .text = "zefir.log: field 'port': cannot log error union 'anyerror!u16'; handle it with try or catch first, then log the payload or the error",
    },
    .{
        .name = "a name that records use themselves",
        .line = "logger.info(\"Request\", .{ .level = 3 }); // compile error: a name records use themselves",
        .text = "zefir.log: field name 'level' is reserved for record metadata; rename it, e.g. 'user_level'",
    },
};
