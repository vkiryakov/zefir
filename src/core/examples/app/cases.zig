//! The examples of README.md, the guide of zefir.App. build.zig compiles
//! the shop with its tests, shop_test.zig, runs stuck.zig, and has
//! readme_test.zig check that README.md shows every file as it is, the run
//! of stuck.zig as it printed, and each compile check of App it shows with
//! its message. The shop's main.zig runs on zio on the network, so
//! tests/app runs it, sends it the guide's curl commands and checks its
//! answers and its log against the guide (`zig build examples` there).

/// The files of the shop and the program that README.md shows as they are.
pub const files = [_][]const u8{
    "Config",
    "Store",
    "users_api",
    "users",
    "orders",
    "health",
    "app_module",
    "main",
    "shop_test",
    "stuck",
};

/// The files of src/core/app/tests/compile_errors/ that README.md shows
/// whole, each followed by its message, as src/core/app/tests/cases.zig
/// holds it.
pub const fixtures = [_][]const u8{ "missing", "cycle_beans", "wrong_shutdown" };

/// The compile checks of App whose message README.md shows without their
/// file.
pub const messages = [_][]const u8{ "two_beans", "controller_two_servers" };

/// The command README.md shows for the run of stuck.zig: a step of its
/// own, since every run of `zig build run` that README.md shows is one of
/// the shop.
pub const stuck_command = "$ zig build stuck";
