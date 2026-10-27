const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service", .version = "1.0.0" },
        .level = .debug, // start verbose: see every step of the start-up
    });
    defer logger.deinit();

    logger.debug("Reading configuration", .{ .path = "config.json" });
    logger.debug("Connecting to the database", .{ .host = "postgres.internal" });
    logger.info("Application started", .{ .port = 9000 });

    logger.setLevel(.info); // started: from now on, info and above only

    logger.debug("Cache miss", .{ .key = "user:42" }); // below info: not written
    logger.info("User created", .{ .user_id = 42 });
}
