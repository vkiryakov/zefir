//! The examples of README.md, the guide of zefir-http. build.zig builds and
//! runs the programs and the tests; readme_test.zig checks that README.md
//! shows every file as it is and every run of a program as it printed.
//! The service of the guide, main.zig, runs on zio on the network, so
//! tests/http runs it, sends it the guide's curl commands and checks its
//! answers and its log against the guide (`zig build examples` there).

/// The programs that run on the backend in memory: `zig build test-http`
/// runs each, and README.md shows its run as `$ zig build run`.
pub const programs = [_][]const u8{ "minute", "app" };

/// The files of the example app that README.md shows as they are. main.zig
/// imports zio, so only tests/http builds it.
pub const files = [_][]const u8{
    "main",
    "Service",
    "TodosV1Controller",
    "SessionController",
    "HealthController",
    "dto",
    "TodoRepository",
    "Billing",
    "middleware",
    "auth",
    "cors",
    "errors",
    "todos_test",
    "middleware_test",
};

/// The files of the app that README.md shows as they are, in other
/// languages: the path in this directory and the language of its block.
pub const other_files = [_][2][]const u8{.{ "public/index.html", "html" }};

/// The programs that README.md at the root of the repository shows too, as
/// they are and with a run of each: its "http in a minute".
pub const root_readme = [_][]const u8{"minute"};

/// The command README.md shows for a run of a program.
pub const command = "$ zig build run";
