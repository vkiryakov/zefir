//! The examples of README.md, the guide of zefir-redis. build.zig runs the
//! tests; readme_test.zig checks that README.md shows every file as it is.
//! The programs that need a server import zio, so only tests/redis builds
//! and runs them, and checks their runs against the guide (`zig build
//! examples` there).

/// The programs that need a server: tests/redis runs them, in this order.
pub const server_programs = [_][]const u8{};

/// The tests of the guide, against `redis.testing.FakeServer`:
/// `zig build test-redis` runs them.
pub const tests = [_][]const u8{ "profiles_test", "deadlines_test", "pipeline_test" };

/// The other files that README.md shows as they are: the code of the
/// application that profiles_test.zig tests.
pub const files = [_][]const u8{"Profiles"};
