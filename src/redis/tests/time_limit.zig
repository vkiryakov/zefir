//! The time limit of the client's tests over loopback: a mistake fails a
//! test instead of hanging it.

const std = @import("std");
const Io = std.Io;

/// Runs `function(args)` in a task of its own and fails with
/// `error.TestTimedOut` when it takes longer than 5 s.
pub fn within5s(io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
    return withinLimit(io, .fromSeconds(5), function, args);
}

/// `within5s` with `limit` in place of 5 s: for a test whose work
/// ThreadSanitizer makes many times slower.
pub fn withinLimit(io: Io, limit: Io.Duration, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
    const Race = union(enum) {
        done: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, Io.sleep, .{ io, limit, .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .done => |result| result,
        .timer => error.TestTimedOut,
    };
}
