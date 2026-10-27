//! zefir-log in a service's main: a threshold for the whole service, one of
//! its own for the database, and the database's threshold changed while the
//! service runs, as an admin endpoint would change it.

const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service", .version = "1.0.0" },
        .level = .info,
        .scopes = &.{.{ .prefix = "db", .level = .warn }},
    });
    defer logger.deinit();

    logger.info("Application started", .{ .port = 9000 });
    logger.debug("Loading configuration", .{}); // below the threshold: not written

    const pool = logger.scoped("db.pool");
    pool.info("Connection opened", .{ .connections = 1 }); // db logs from warn: not written
    pool.warn("Pool is almost full", .{ .connections = 19, .max = 20 });

    try logger.setScopeLevel("db", .debug); // say, from an admin endpoint
    pool.debug("Waiting for a connection", .{ .waiting_ms = 340 });

    try logger.setScopeLevel("db", null); // back to the global threshold
    pool.debug("Connection reused", .{ .connections = 19 }); // not written again
}
