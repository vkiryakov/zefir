//! Must not compile: the calls that README.md shows the build refusing,
//! one test each, every call as README.md shows it. build.zig compiles
//! each test on its own and expects the error that cases.zig gives for it.

const log = @import("log");

/// Never called at run time: these tests only have to fail to compile.
fn anyLogger() log.Logger {
    return undefined;
}

test "a field without a name" {
    const logger = anyLogger();
    const user_id: u64 = 42;
    logger.info("User created", .{user_id}); // compile error: a field without a name
}

test "an error union as a value" {
    const logger = anyLogger();
    const port: anyerror!u16 = 9000;
    logger.info("Listening", .{ .port = port }); // compile error: port is an anyerror!u16
}

test "a name that records use themselves" {
    const logger = anyLogger();
    logger.info("Request", .{ .level = 3 }); // compile error: a name records use themselves
}
