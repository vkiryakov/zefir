//! `redis.Subscriber`: the messages of channels and patterns, on a
//! connection of its own, from `client.subscribe` until `close`.
//!
//! ```zig
//! var sub = try client.subscribe(io, op, .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
//! defer sub.close(io);
//! ```
//!
//! - `client.subscribe` opens a connection outside the pool, with the
//!   handshake of the pool's connections, sends SUBSCRIBE with the channels
//!   and PSUBSCRIBE with the patterns in one write, and returns once the
//!   server has confirmed each name, within the deadline of `op`, else
//!   `timeout` of the options from now. A refusal, such as NOPERM for a
//!   channel the user may not read, is `error.ServerError` of `subscribe`
//!   with the server's code in the diagnostics, and the connection closes.
//!   The channels and the patterns stay as they are: to change them, close
//!   the subscriber and subscribe again.
//! - The connection of a subscriber is not one of `max_connections`;
//!   `client.stats()` counts the subscribers in `subscribers`.

const std = @import("std");
const Io = std.Io;
const Client = @import("Client.zig");
const subscription = @import("engine/subscription.zig");
const Subscriber = @This();

client: *Client,
/// The subscriber's state, in the heap, where the client reaches it; null
/// once `close` has freed it.
state: std.atomic.Value(?*subscription.State),

/// A message of a channel.
pub const Message = struct {
    /// The channel it was published to.
    channel: []const u8,
    /// What was published, byte for byte.
    payload: []const u8,
    /// The pattern it came by; null for a channel of `channels`.
    pattern: ?[]const u8 = null,
};

/// Closes the connection and frees the subscriber. A second call does
/// nothing.
pub fn close(sub: *Subscriber, io: Io) void {
    const state = sub.state.swap(null, .acq_rel) orelse return;
    sub.client.subscribers.remove(io, state);
    state.destroy();
}
