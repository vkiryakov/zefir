//! The examples of README.md, the guide of zefir-odm. build.zig builds
//! and runs the programs that need no server and the tests, all on
//! `odm.testing.FakeDriver`; readme_test.zig checks that README.md shows
//! every file as it is and the run of each of those programs as it
//! printed. The programs that need mongod import zio and zefir-mongo, so
//! only tests/odm builds and runs them, and checks their runs against the
//! guide (`zig build examples` there): nothing that `zig build test-odm`
//! builds imports zefir-mongo.

/// The programs that need no server: `zig build test-odm` runs each, and
/// README.md shows its run as `$ zig build run`.
pub const programs = [_][]const u8{ "models", "queries", "app" };

/// The programs that need mongod: tests/odm runs them.
pub const server_programs = [_][]const u8{ "quick_start", "tenants", "rotation", "errors" };

/// The tests of the guide, on `odm.testing.FakeDriver`: `zig build
/// test-odm` runs them.
pub const tests = [_][]const u8{ "users_test", "conformance_test" };

/// The other files that README.md shows as they are: the code of the
/// application that the tests of the guide test.
pub const files = [_][]const u8{"Users"};

/// The command README.md shows for a run of a program without a server.
pub const command = "$ zig build run";
