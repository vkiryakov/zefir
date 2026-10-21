//! The examples of README.md, the guide of zefir-jwt. build.zig builds and
//! runs the programs and the tests; readme_test.zig checks that README.md
//! shows every file as it is and every run as it printed.

/// A setting of a program, which it reads from the environment with confy.
pub const Setting = struct {
    /// The variable, such as `APP_AUTH_KEY_ID`.
    name: []const u8,
    /// Its value when the build runs the program.
    value: []const u8,
    /// How README.md writes it in the command, when not as `value`.
    shown: ?[]const u8 = null,
};

/// A program of the guide: it signs, verifies and serves in memory, and
/// logs with zefir-log as text.
pub const Program = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The settings it reads. README.md shows its run as
    /// `$ <NAME>=<value> ... zig build run`, and the build runs it with
    /// them.
    env: []const Setting = &.{},
};

/// The programs: `zig build test-jwt` runs them.
pub const programs = [_]Program{};

/// The other files README.md shows as they are: the code of the services
/// and their tests.
pub const files = [_][]const u8{};

/// The tests among `files`: `zig build test-jwt` runs them.
pub const tests = [_][]const u8{};

/// The command README.md shows for a run of `program`.
pub fn command(comptime program: Program) []const u8 {
    comptime var line: []const u8 = "$ ";
    inline for (program.env) |setting| line = line ++ setting.name ++ "=" ++ (setting.shown orelse setting.value) ++ " ";
    return line ++ "zig build run";
}
