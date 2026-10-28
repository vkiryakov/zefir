const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .mode = .{ .queued = .{} },
    });
    defer logger.deinit();

    // The disk is full and the service is about to stop: the record goes to
    // stderr before the call returns, whatever the queue still holds.
    logger.emergency("Disk full", .{ .path = "/var/lib/app", .free_bytes = 0 });
}
