//! Running a task against a deadline, as `src/nats/engine/connect.zig`
//! does: `race` runs a function in a task of its own and waits for it
//! until the deadline, then stops it. A task blocked on a socket may lose
//! its cancelation (code it calls can swallow `error.Canceled`), so an
//! abort hook makes it return, by shutting its socket down.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const time = @import("time.zig");

/// The errors of `race(function, ...)`: those of `function`, plus
/// `Timeout` when the deadline came first.
pub fn RaceError(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.error_set ||
        error{ Timeout, Canceled, ConcurrencyUnavailable };
}

/// What `function` returns when it succeeds.
pub fn Payload(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.payload;
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// How `race` makes a task that ran out of time return soon besides
/// canceling it.
pub const Abort = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, io: Io) void,
};

/// Runs `function(args)` in a task of its own and waits for it until
/// `deadline`. When the deadline comes first, the task is aborted,
/// canceled and awaited, a value it returned anyway goes to `release`, and
/// the caller gets `error.Timeout`. Canceling the caller stops the task the
/// same way.
pub fn race(
    io: Io,
    deadline: core.Deadline,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: fn (Io, Payload(@TypeOf(function))) void,
    abort: ?Abort,
) RaceError(@TypeOf(function))!Payload(@TypeOf(function)) {
    const Race = union(enum) {
        done: Result(@TypeOf(function)),
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, time.sleepUntil, .{ io, deadline }) catch |err| {
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
        .timer => error.Timeout,
    };
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
    try testing.expectEqual(@as(u32, 7), try race(io, .after(time.now(io), .fromSeconds(30)), sleepThenAnswer, .{ io, .fromMilliseconds(1) }, keep, null));
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(30));
    try testing.expectError(error.Timeout, race(io, deadline, sleepThenAnswer, .{ io, .fromSeconds(30) }, keep, null));
    try testing.expect(time.expired(io, deadline));
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
    try testing.expectError(error.Timeout, race(io, .after(time.now(io), .fromMilliseconds(20)), waitDeaf, .{ io, &event }, keep, .{
        .context = &event,
        .function = setEvent,
    }));
    try testing.expect(event.isSet());
    try testing.expect(start.durationTo(time.now(io)).toSeconds() < 3);
}
