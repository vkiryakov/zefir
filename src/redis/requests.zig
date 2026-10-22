//! The arguments of the client's calls besides the command: the caller's
//! context and the options. They are structs, so that a later release
//! adds a field with a default without breaking callers.

const std = @import("std");
const core = @import("core");
const Diagnostics = @import("errors.zig").Diagnostics;

/// The caller's context of one call.
pub const OperationContext = struct {
    /// The deadline, the cancellation token and the W3C trace of the
    /// caller. The call waits no longer than the deadline, in the line of
    /// the pool too, and the client checks the token before it sends.
    ctx: core.Context,
    /// For the client's logs; never sent to the server.
    tracing: Tracing = .{},

    pub fn of(ctx: core.Context) OperationContext {
        return .{ .ctx = ctx };
    }
};

pub const Tracing = struct {
    /// The caller's operation, such as "sessions.get".
    operation: ?[]const u8 = null,
};

pub const RunOptions = struct {
    /// The memory of the reply, an arena: the client takes from it during
    /// the call only and frees nothing, so the reply lives as long as the
    /// arena. A reply whose type holds strings or slices needs it; for
    /// numbers, bools, enums and `void` it may stay null.
    allocator: ?std.mem.Allocator = null,
    diagnostics: ?*Diagnostics = null,
};

pub const IterateOptions = struct {
    /// The memory of the pages: the iterator holds each in an arena of its
    /// own over it until the next page, and frees it in `deinit`, so a
    /// general purpose allocator does.
    allocator: std.mem.Allocator,
    /// What went wrong with a page: each `next` that fetches one sets it.
    diagnostics: ?*Diagnostics = null,
};

pub const SubscribeOptions = struct {
    /// The channels whose messages come, by their names: SUBSCRIBE.
    channels: []const []const u8 = &.{},
    /// The patterns of channels whose messages come, such as `events.*`:
    /// PSUBSCRIBE. One of the two lists has a name at least.
    patterns: []const []const u8 = &.{},
    /// After this long without a frame from the server, the subscriber
    /// sends PING; when nothing comes within as long again, `next` is
    /// `error.ConnectionLost`. 1 ms or more.
    idle_ping: std.Io.Duration = .fromSeconds(15),
    /// Why `subscribe` failed; the errors of `next` go to
    /// `Subscriber.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
};
