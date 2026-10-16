//! The counters of one route of `rpc.RawServer`, for
//! `rpc.transport.Dispatcher.routeStats` (NATS micro STATS). Internal to the
//! module.

const std = @import("std");
const model = @import("../model.zig");
const Dispatcher = @import("../Dispatcher.zig");

const RouteStats = @This();

/// Calls of the route, counted at admission, refused ones included.
requests: std.atomic.Value(u64) = .init(0),
/// Calls that ended without a successful response.
errors: std.atomic.Value(u64) = .init(0),
/// The time of the calls that ran, from the head to their end, summed;
/// saturates.
processing_ns: std.atomic.Value(u64) = .init(0),
/// Guards `last_error`; held for a copy only.
mutex: std.Io.Mutex = .init,
last_error: ?Dispatcher.RouteStats.LastError = null,

pub fn countRequest(s: *RouteStats) void {
    _ = s.requests.fetchAdd(1, .monotonic);
}

/// A call ended in `failure`, or without a response.
pub fn countFailure(s: *RouteStats, io: std.Io, failure: model.Failure) void {
    _ = s.errors.fetchAdd(1, .monotonic);
    const last: Dispatcher.RouteStats.LastError = .init(failure.code, failure.app_code);
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    s.last_error = last;
}

pub fn addTime(s: *RouteStats, duration: std.Io.Duration) void {
    const ns: u64 = @intCast(std.math.clamp(duration.nanoseconds, 0, std.math.maxInt(u64)));
    var current = s.processing_ns.load(.monotonic);
    while (s.processing_ns.cmpxchgWeak(current, current +| ns, .monotonic, .monotonic)) |seen| current = seen;
}

/// The counters now, as a value that owns all it holds.
pub fn snapshot(s: *RouteStats, io: std.Io) Dispatcher.RouteStats {
    const last = last: {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        break :last s.last_error;
    };
    return .{
        .requests = s.requests.load(.monotonic),
        .errors = s.errors.load(.monotonic),
        .processing_time = .fromNanoseconds(s.processing_ns.load(.monotonic)),
        .last_error = last,
    };
}

const testing = std.testing;

test "route stats count requests, failures and time, and keep a copy of the last failure" {
    const io = testing.io;
    var s: RouteStats = .{};
    const empty = s.snapshot(io);
    try testing.expectEqual(@as(u64, 0), empty.requests);
    try testing.expectEqual(@as(?Dispatcher.RouteStats.LastError, null), empty.last_error);

    s.countRequest();
    s.countRequest();
    s.addTime(.fromMilliseconds(3));
    s.addTime(.fromMilliseconds(-5));
    var app_code = "users.not_found".*;
    s.countFailure(io, .{ .code = .not_found, .app_code = &app_code, .message = "User not found" });
    app_code[0] = 'X';
    const stats = s.snapshot(io);
    try testing.expectEqual(@as(u64, 2), stats.requests);
    try testing.expectEqual(@as(u64, 1), stats.errors);
    try testing.expectEqual(@as(i64, 3), stats.processing_time.toMilliseconds());
    try testing.expectEqualStrings("users.not_found", stats.last_error.?.appCode());

    // The sum saturates instead of wrapping.
    s.addTime(.max);
    s.addTime(.fromSeconds(1));
    try testing.expectEqual(@as(i96, std.math.maxInt(u64)), s.snapshot(io).processing_time.nanoseconds);
}
