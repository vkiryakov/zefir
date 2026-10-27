const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    // The records go to a writer that throws them away: this program shows
    // only the counters.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .mode = .{ .queued = .{ .capacity = 64, .overflow = .block } },
        .output = .{ .writer = &discard.writer },
    });
    defer logger.deinit();

    for (0..10_000) |i| logger.info("Cache refreshed", .{ .entry = i });
    logger.flush(.{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {};

    const s = logger.stats();
    std.debug.print("accepted {d}, written {d}, dropped because the queue was full {d}\n", .{ s.accepted, s.written, s.dropped.queue_full });
}
