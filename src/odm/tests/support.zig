//! What the tests of the registry share: the result of a call made in a
//! task of its own, and a wait on the clock for a condition.

const std = @import("std");
const Io = std.Io;
const odm = @import("../root.zig");

/// The errors of the calls of the registry, `shutdown` with them.
pub const CallError = odm.Error || odm.ShutdownError;

/// The result of one call of the registry in a task of its own.
pub const Outcome = struct {
    result: CallError!void = {},
    done: std.atomic.Value(bool) = .init(false),

    pub fn set(o: *Outcome, result: CallError!void) void {
        o.result = result;
        o.done.store(true, .release);
    }

    fn isDone(o: *Outcome, io: Io) bool {
        _ = io;
        return o.done.load(.acquire);
    }

    /// The result, once the call returned; error.Timeout after 5 s.
    pub fn wait(o: *Outcome, io: Io) !CallError!void {
        try eventually(io, o, isDone);
        return o.result;
    }
};

/// Until `holds(arg, io)`, looking every millisecond; error.Timeout after
/// 5 s on the .awake clock, so that a call that never returns fails the
/// test.
pub fn eventually(io: Io, arg: anytype, comptime holds: fn (@TypeOf(arg), Io) bool) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (!holds(arg, io)) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("the registry did not get there in 5 s\n", .{});
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
