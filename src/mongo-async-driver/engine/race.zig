//! Running a task against a deadline, as `src/nats/engine/connect.zig`
//! does: `race` runs a function in a task of its own and waits for it
//! until the deadline, or until another task stops it, then stops it. A
//! task blocked on a socket may lose its cancelation (code it calls can
//! swallow `error.Canceled`, as the stack traces of std's testing
//! allocator do on macOS), so an abort hook makes it return, by cutting
//! its stream (`DeadlineStream.cut`).

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const time = @import("time.zig");

/// The errors of `race(function, ...)`: those of `function`, plus
/// `Timeout` when the deadline came first and `Stopped` when the stop did.
pub fn RaceError(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.error_set ||
        error{ Timeout, Stopped, Canceled, ConcurrencyUnavailable };
}

/// What `function` returns when it succeeds.
pub fn Payload(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.payload;
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// What ends the wait for the task, besides the task itself: the
/// deadline, and `stop`, an event that another task sets. Null: none.
pub const Until = struct {
    deadline: ?core.Deadline = null,
    stop: ?*Io.Event = null,
};

/// How `race` makes a task that ran out of time return soon besides
/// canceling it.
pub const Abort = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, io: Io) void,
};

/// Runs `function(args)` in a task of its own and waits for it until
/// `until` ends the wait. When the deadline comes first, or the stop, the
/// task is aborted, canceled and awaited, a value it returned anyway goes
/// to `release`, and the caller gets `error.Timeout` or `error.Stopped`:
/// the cancelation that `race` gave the task is no cancelation of the
/// caller. Canceling the caller stops the task the same way, and the
/// caller gets `error.Canceled`.
pub fn race(
    io: Io,
    until: Until,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: fn (Io, Payload(@TypeOf(function))) void,
    abort: ?Abort,
) RaceError(@TypeOf(function))!Payload(@TypeOf(function)) {
    const Race = union(enum) {
        done: Result(@TypeOf(function)),
        timer: Io.Cancelable!End,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, wait, .{ io, until }) catch |err| {
        if (abort) |a| a.function(a.context, io);
        settle(Race, &select, io, release);
        return err;
    };
    const first = select.await() catch |err| {
        if (abort) |a| a.function(a.context, io);
        settle(Race, &select, io, release);
        return err;
    };
    if (first == .timer) if (abort) |a| a.function(a.context, io);
    settle(Race, &select, io, release);
    return switch (first) {
        .done => |result| result,
        .timer => |end| if ((end catch .deadline) == .stop) error.Stopped else error.Timeout,
    };
}

/// What ended the wait of `race`.
const End = enum { deadline, stop };

/// Waits until the deadline of `until` passes or its stop is set,
/// whichever comes first; with neither, until canceled.
fn wait(io: Io, until: Until) Io.Cancelable!End {
    while (true) {
        if (until.stop) |stop| if (stop.isSet()) return .stop;
        if (until.deadline) |deadline| if (time.expired(io, deadline)) return .deadline;
        const step = time.step(io, until.deadline).toTimeout();
        if (until.stop) |stop| {
            stop.waitTimeout(io, step) catch |err| switch (err) {
                // The deadline, a step of a far one or of none, or a
                // spurious wakeup: the loop looks again.
                error.Timeout => {},
                error.Canceled => |e| return e,
            };
        } else try step.sleep(io);
    }
}

/// Cancels and awaits what is still running; a value that arrives anyway
/// goes to `release`.
fn settle(comptime Race: type, select: *Io.Select(Race), io: Io, comptime release: anytype) void {
    while (select.cancel()) |left| switch (left) {
        .done => |result| if (result) |value| release(io, value) else |_| {},
        .timer => {},
    };
}

const testing = std.testing;

fn sleepThenAnswer(io: Io, duration: Io.Duration) error{Canceled}!u32 {
    try io.sleep(duration, .awake);
    return 7;
}

fn keep(io: Io, value: u32) void {
    _ = io;
    _ = value;
}

test "race returns what comes in time, and gives up at the deadline" {
    const io = testing.io;
    try testing.expectEqual(@as(u32, 7), try race(io, .{ .deadline = .after(time.now(io), .fromSeconds(30)) }, sleepThenAnswer, .{ io, .fromMilliseconds(1) }, keep, null));
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(30));
    try testing.expectError(error.Timeout, race(io, .{ .deadline = deadline }, sleepThenAnswer, .{ io, .fromSeconds(30) }, keep, null));
    try testing.expect(time.expired(io, deadline));
}

fn setAfter(io: Io, event: *Io.Event, duration: Io.Duration) Io.Cancelable!void {
    try io.sleep(duration, .awake);
    event.set(io);
}

test "a stop that another task sets ends the wait at once: Stopped, with a deadline or with none" {
    const io = testing.io;
    for ([_]?core.Deadline{ null, .after(time.now(io), .fromSeconds(30)) }) |deadline| {
        var stop: Io.Event = .unset;
        var setter = try io.concurrent(setAfter, .{ io, &stop, .fromMilliseconds(20) });
        defer setter.cancel(io) catch {};
        const start = time.now(io);
        try testing.expectError(error.Stopped, race(io, .{ .deadline = deadline, .stop = &stop }, sleepThenAnswer, .{ io, .fromSeconds(30) }, keep, null));
        try testing.expect(start.durationTo(time.now(io)).toSeconds() < 3);
    }
}

/// Waits for `event` and ignores cancelation, like code that swallows
/// error.Canceled; gives up after 5 s.
fn waitDeaf(io: Io, event: *Io.Event) error{Abandoned}!u32 {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(5));
    while (!event.isSet()) {
        event.waitTimeout(io, give_up.toTimeout()) catch {};
        if (time.expired(io, give_up)) return error.Abandoned;
    }
    return 1;
}

fn setEvent(context: *anyopaque, io: Io) void {
    const event: *Io.Event = @ptrCast(@alignCast(context));
    event.set(io);
}

test "a task that ignores cancelation is stopped through the abort hook" {
    const io = testing.io;
    var event: Io.Event = .unset;
    const start = time.now(io);
    try testing.expectError(error.Timeout, race(io, .{ .deadline = .after(time.now(io), .fromMilliseconds(20)) }, waitDeaf, .{ io, &event }, keep, .{
        .context = &event,
        .function = setEvent,
    }));
    try testing.expect(event.isSet());
    try testing.expect(start.durationTo(time.now(io)).toSeconds() < 3);
}
