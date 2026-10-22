//! Pipelines against the server that REDIS_IMAGE names: 10 000 commands
//! go out in one exchange, and their replies come back in order.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// INCR of a key built at run time.
const Incr = cmd.Raw(i64, []const []const u8);

test "10 000 INCR of one key in one pipeline count from 1 to 10 000, in order" {
    try e2e.onZio(tenThousand);
}

fn tenThousand(io: Io) !void {
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = "redis://127.0.0.1:16379" });
    defer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    const key = "e2e:pipeline:views";
    _ = try client.run(io, within(io, .fromSeconds(10)), cmd.raw(u64, .{ "DEL", key }), .{});
    const parts: []const []const u8 = &.{ "INCR", key };
    const commands = try testing.allocator.alloc(Incr, 10_000);
    defer testing.allocator.free(commands);
    @memset(commands, cmd.raw(i64, parts));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const counts = client.pipeline(io, within(io, .fromSeconds(30)), commands, .{ .allocator = arena.allocator(), .diagnostics = &d }) catch |err| {
        std.debug.print("pipeline: {t}: {s}, {?d} answered\n", .{ err, d.message(), d.answered });
        return err;
    };
    try testing.expectEqual(@as(usize, 10_000), counts.len);
    for (counts, 1..) |count, n| try testing.expectEqual(@as(i64, @intCast(n)), try count);
    try testing.expectEqual(@as(?i64, 10_000), try client.run(io, within(io, .fromSeconds(10)), cmd.raw(?i64, .{ "GET", key }), .{}));
    // The pool kept the one connection of the pipeline.
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
}
