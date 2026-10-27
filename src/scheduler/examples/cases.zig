//! The examples of README.md, the guide of zefir-scheduler. build.zig
//! builds and runs the programs that need no server and the tests, all on
//! `scheduler.MemoryStore`; readme_test.zig checks that README.md shows
//! every file as it is and the run of each of those programs as it
//! printed. The programs that need mongod import zio and zefir-mongo, so
//! only tests/scheduler builds and runs them, and checks their runs
//! against the guide (`zig build examples` there): nothing that `zig build
//! test-scheduler` builds imports zefir-mongo.

/// The programs that need no server: `zig build test-scheduler` runs
/// each, and README.md shows its run as `$ zig build run`.
pub const programs = [_][]const u8{ "quick_start", "schedules", "orders", "failures", "app" };

/// The programs that need mongod: tests/scheduler runs them.
pub const server_programs = [_][]const u8{ "mongo_quick_start", "instances" };

/// The tests of the guide, on `scheduler.MemoryStore`: `zig build
/// test-scheduler` runs them.
pub const tests = [_][]const u8{"jobs_test"};

/// The other files that README.md shows as they are: the code of the
/// application that the tests of the guide test.
pub const files = [_][]const u8{"Invoices"};

/// The command README.md shows for a run of a program.
pub const command = "$ zig build run";
