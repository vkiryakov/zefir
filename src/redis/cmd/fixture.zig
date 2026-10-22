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
