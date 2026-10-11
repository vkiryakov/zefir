//! zefir-log in a service's main: JSON records on stdout, a scoped handle,
//! a redacted secret and a level changed at run time. `zig build test`
//! runs it; it fails if the logger loses a record.

const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service", .instance_id = "replica-01", .version = "1.0.0" },
        .level = .info,
        .scopes = &.{.{ .prefix = "db", .level = .warn }},
    });
    defer logger.deinit();

    logger.info("Application started", .{ .port = 9000 });
    logger.debug("Loading configuration", .{}); // below the threshold: not written

    const users = logger.scoped("users");
    var user_id: u64 = 42;
    _ = &user_id;
    users.info("User created", .{ .user_id = user_id, .email = "ada@example.com", .password = "hunter2" });

    const db = logger.scoped("db.pool");
    db.info("Connection opened", .{}); // "db" logs from warn: not written
    try logger.setScopeLevel("db", .debug);
    db.debug("Connection reused", .{ .connections = 3 });

    logger.err("Payment failed", .{ .order_id = 1001, .reason = error.CardDeclined });

    const counts = logger.stats();
    if (counts.written != 4 or counts.dropped.write_failed != 0) return error.LostRecords;
}
