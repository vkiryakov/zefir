//! The examples of README.md, the guide of rpc and rpc-log. build.zig
//! builds and runs the programs and the tests; readme_test.zig checks that
//! README.md shows every file as it is and every run as it printed.

/// A program of the guide: a whole service, or a service and its clients,
/// that logs what happens with zefir-log as text.
pub const Program = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The settings it reads from the environment with confy. README.md
    /// shows its run as `$ <NAME>=<value> ... zig build run`, and the
    /// build runs it with them.
    env: []const [2][]const u8 = &.{},
};

/// The programs that use zefir-rpc, zefir-core, zefir-validator,
/// zefir-confy and zefir-log: `zig build test-rpc` runs them.
pub const programs = [_]Program{
    .{ .name = "minute" },
    .{ .name = "getting_started" },
    .{ .name = "orders" },
    .{ .name = "service", .env = &.{
        .{ "APP_AUTH_ADMIN_TOKEN", "admin-secret" },
        .{ "APP_AUTH_REPORTING_TOKEN", "reporting-secret" },
    } },
    .{ .name = "idempotency" },
    .{ .name = "shutdown" },
};

/// The programs that also use zefir-rpc-log: `zig build test-rpc-log` runs
/// them.
pub const access_log_programs = [_]Program{
    .{ .name = "access_log" },
};

/// The other files README.md shows as they are: the packages of the
/// contracts, the files the programs import, and the tests.
pub const files = [_][]const u8{
    "users_api",
    "orders_api",
    "UserRepository",
    "UserHandler",
    "Store",
    "middleware",
    "TokenAuthenticator",
    "users_test",
};

/// The tests among `files`: `zig build test-rpc` runs them.
pub const tests = [_][]const u8{"users_test"};

/// The programs that README.md at the root of the repository shows too, as
/// they are and with a run of each: its "rpc in a minute".
pub const root_readme = [_][]const u8{"minute"};

/// The command README.md shows for a run of `program`.
pub fn command(comptime program: Program) []const u8 {
    comptime var line: []const u8 = "$ ";
    inline for (program.env) |pair| line = line ++ pair[0] ++ "=" ++ pair[1] ++ " ";
    return line ++ "zig build run";
}

/// The parts of a record that change from run to run, and that a run in
/// README.md may show with values of its own: the timestamp at the start
/// of every line, and the values of these fields.
pub const varying_fields = [_][]const u8{ "rpc.request_id", "rpc.duration_ms", "span_id" };
