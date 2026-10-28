const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service", .version = "1.0.0" },
        .format = .text, // one line for people: the service fields are left out
    });
    defer logger.deinit();

    logger.info("Application started", .{ .port = 9000 });

    const users = logger.scoped("users");
    users.info("User created", .{ .user_id = 42, .email = "ada@example.com", .password = "hunter2" });
    users.warn("Slow query", .{ .table = "users", .ms = 1250 });

    logger.err("Payment failed", .{ .order_id = 1001, .reason = error.CardDeclined });
}
