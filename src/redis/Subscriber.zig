//! `redis.Subscriber`: the messages of channels and patterns, on a
//! connection of its own, from `client.subscribe` until `close`.
//!
//! ```zig
//! var sub = try client.subscribe(io, op, .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
//! defer sub.close(io);
//! while (try sub.next(io)) |message| {
//!     try orders.put(message.payload); // the message lives until the next next
//! }
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
//! - `next` waits for the next message without a deadline: a subscriber
//!   lives long. The message lies in the subscriber's own memory until the
//!   next call, however large: up to `max_reply_bytes`, beyond which it is
//!   `error.ReplyTooLarge`. Keep the loop of `next` quick, and hand the
//!   messages to a queue of your own: a server closes a subscriber that
//!   falls behind (`client-output-buffer-limit pubsub`, 32 MiB by default).
//! - Silence. A dead connection is silent, and without TCP keepalive it
//!   stays so: after `idle_ping` without a frame (15 s by default) the
//!   subscriber sends PING, which the server answers on the subscribed
//!   connection too, and when no frame comes within `idle_ping` again,
//!   `next` is `error.ConnectionLost`. The bytes of a message that has
//!   begun may each wait `idle_ping` too. The PING is no retry: no command
//!   of the caller's goes again.
//! - A connection that breaks, or that the server closes, is
//!   `error.ConnectionLost`; a task canceled while `next` waits is
//!   `error.Interrupted`, and keeps its cancelation. After any error the
//!   connection is closed and `next` is `error.Closed`: close the
//!   subscriber and subscribe again. The messages published meanwhile are
//!   lost, and nothing subscribes again by itself. `diagnostics()` holds
//!   the details of the error of the last `next`.
//! - Pushes other than messages are skipped, and so is the reply to the
//!   subscriber's own PING.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const calls = @import("calls.zig");
const Client = @import("Client.zig");
const subscription = @import("engine/subscription.zig");
const Subscriber = @This();

client: *Client,
/// The subscriber's state, in the heap, where the client reaches it; null
/// once `close` has freed it.
state: std.atomic.Value(?*subscription.State),
/// What went wrong in the last `next`.
details: Diagnostics = .{},

/// A message of a channel.
pub const Message = struct {
    /// The channel it was published to.
    channel: []const u8,
    /// What was published, byte for byte.
    payload: []const u8,
    /// The pattern it came by; null for a channel of `channels`.
    pattern: ?[]const u8 = null,
};

/// The next message, which lives until the next call; null once the
/// subscriber is closed. It waits as long as it takes, sending PING after
/// `idle_ping` of silence. What went wrong goes to `diagnostics()`; after
/// an error the subscriber is done with, and `next` is `error.Closed`.
pub fn next(sub: *Subscriber, io: Io) Error!?Message {
    const state = sub.state.load(.acquire) orelse return null;
    calls.checkUse(sub.client, io);
    const d = &sub.details;
    d.* = .{};
    if (state.failed) return calls.fail(d, null, error.Closed, "the subscriber lost its connection to an error before: close it, and subscribe again", .{});
    return state.receive(io, d) catch |err| {
        state.fail(io);
        return err;
    };
}

/// The details of the error of the last `next`.
pub fn diagnostics(sub: *const Subscriber) *const Diagnostics {
    return &sub.details;
}

/// Closes the connection and frees the subscriber. A second call does
/// nothing.
pub fn close(sub: *Subscriber, io: Io) void {
    const state = sub.state.swap(null, .acq_rel) orelse return;
    sub.client.subscribers.remove(io, state);
    state.destroy();
}
