//! The checks S and L of zefir-mongo's client, from the file of the zefir
//! package that `zig build test-mongo` runs layer S of
//! (src/mongo/tests/checks.zig): layer S against the scripted server of
//! each check, layer L against mongo-plain, with fail points.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const checks = @import("checks");
const e2e = @import("root.zig");

test "the checks S and L of the client: S against the scripted server of each check, L with fail points against mongo-plain" {
    try e2e.onZio(everyCheck);
}

fn everyCheck(io: Io) !void {
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port});
    for (std.enums.values(checks.Check)) |check| {
        try checks.run(io, testing.allocator, check, .{ .live = .{ .uri = uri, .fail_points = true } });
    }
}
