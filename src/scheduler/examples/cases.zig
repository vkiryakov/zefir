//! The examples of the guide of zefir-scheduler. The programs that need
//! mongod import zio and zefir-mongo, so only tests/scheduler builds and
//! runs them (`zig build examples` there): nothing that `zig build
//! test-scheduler` builds imports zefir-mongo.

/// The programs that need mongod: tests/scheduler runs them.
pub const server_programs = [_][]const u8{ "mongo_quick_start", "instances" };
