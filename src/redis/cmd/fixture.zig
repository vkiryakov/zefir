//! A client for the tests of the catalog: a real `redis.Client`, connected
//! to a `redis.testing.FakeServer` that plays the script of a test, with
//! an arena for the replies. The steps of the script expect the exact
//! arguments of each command, and answer it in the RESP3 form that a
//! server gives it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const Client = redis.Client;
const FakeServer = redis.testing.FakeServer;
const time = @import("../engine/time.zig");

pub const Fixture = struct {
    client: Client,
    arena: std.heap.ArenaAllocator,
    /// The diagnostics of the last call.
    d: redis.Diagnostics = .{},

    /// Connects the client to `server`. The fixture stays where it is
    /// until `deinit`, since the client must not move.
    pub fn init(f: *Fixture, io: Io, server: *const FakeServer) !void {
        f.* = .{ .client = try .init(testing.allocator, io, .{ .url = server.url() }), .arena = .init(testing.allocator) };
        errdefer f.deinit();
        try f.client.connect(io, .root, null);
    }

    pub fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.arena.deinit();
    }

    /// Runs `command` without a deadline of its own, its reply in the
    /// arena and what went wrong in `d`.
    pub fn run(f: *Fixture, io: Io, command: anytype) redis.Error!Client.ReplyOf(@TypeOf(command)) {
        return f.runIn(io, .of(.root), command);
    }

    /// Runs `command` under `op`.
    pub fn runIn(f: *Fixture, io: Io, op: redis.OperationContext, command: anytype) redis.Error!Client.ReplyOf(@TypeOf(command)) {
        return f.client.run(io, op, command, .{ .allocator = f.arena.allocator(), .diagnostics = &f.d });
    }
};

/// The context of a call that must end within `duration` from now.
pub fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

/// Checks `timeout_ms`, the timeout that a blocking command sent under a
/// deadline of 1 s set at `since` or later: what that deadline left
/// beyond the margin of 150 ms as the command went out, so 850 at most,
/// and less than 850 by no more than the time since `since`, which a
/// loaded machine may stretch. The exact rule is the test of
/// `blocking.derive`.
pub fn expectFromDeadline(io: Io, since: Io.Timestamp, timeout_ms: u64) !void {
    const elapsed: u64 = @intCast(since.durationTo(time.now(io)).toMilliseconds());
    if (timeout_ms <= 850 and timeout_ms + elapsed + 1 >= 850) return;
    std.debug.print("a timeout of {d} ms from a deadline of 1 s, {d} ms after the deadline was set\n", .{ timeout_ms, elapsed });
    return error.TestUnexpectedResult;
}

/// A handler of `FakeServer` that answers each command with the next of
/// `replies`, in the order the commands come: for commands whose
/// arguments vary, such as a timeout taken from a deadline.
pub const Replies = struct {
    replies: []const FakeServer.Reply,
    next: std.atomic.Value(usize) = .init(0),

    pub fn answer(r: *Replies, _: Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        const i = r.next.fetchAdd(1, .acq_rel);
        return if (i < r.replies.len) r.replies[i] else .{ .err = "ERR zefir test: no more replies" };
    }
};
