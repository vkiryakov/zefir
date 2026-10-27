//! The examples of README.md, the guide of zefir-mongo. build.zig builds
//! and runs the program that needs no server and the tests;
//! readme_test.zig checks that README.md shows every file as it is and the
//! run of that program as it printed. The programs that need mongod
//! import zio, so only tests/mongo builds and runs them, and checks their
//! runs against the guide (`zig build examples` there).

/// The programs that need no server: `zig build test-mongo` runs each, and
/// README.md shows its run as `$ zig build run`.
pub const programs = [_][]const u8{"documents"};

/// The programs that need mongod: tests/mongo runs them.
pub const server_programs = [_][]const u8{ "quick_start", "connect", "orders", "reports", "errors", "durable", "app" };

/// The tests of the guide, against `mongo.testing.FakeServer`:
/// `zig build test-mongo` runs them.
pub const tests = [_][]const u8{ "users_test", "deadlines_test", "import_test" };

/// The other files that README.md shows as they are: the code of the
/// application that users_test.zig tests.
pub const files = [_][]const u8{"Users"};

/// The command README.md shows for a run of a program without a server.
pub const command = "$ zig build run";
