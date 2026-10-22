//! `redis.Subscriber`: the messages of channels and patterns, on a
//! connection of its own, from `client.subscribe` until `close`; its
//! memory until `deinit`.
//!
//! ```zig
//! var sub = try client.subscribe(io, op, .{ .channels = &.{"orders"}, .patterns = &.{"events.*"} });
//! defer sub.deinit();
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
//!   `client.stats()` counts the subscribers in `subscribers`, each until
//!   its `close`.
//! - `next` waits for the next message without a deadline: a subscriber
//!   lives long. The message lies in the subscriber's own memory until the
//!   next call of `next`, however large: up to `max_reply_bytes`, beyond
//!   which it is `error.ReplyTooLarge`. Keep the loop of `next` quick, and
//!   hand the messages to a queue of your own: a server closes a
//!   subscriber that falls behind (`client-output-buffer-limit pubsub`,
//!   32 MiB by default).
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
//! - `close` may come from any task: it cuts the connection, so that the
//!   `next` that waits in another task returns null, and so does every
//!   later one; it returns once that `next` has, and closes the
//!   connection. A message that the reading task holds stays as it came
//!   until its next `next`. The client's `close` ends every subscriber the
//!   same way.
//! - `deinit` frees the subscriber, and closes it first if nobody has.
//!   Call it once no task reads the subscriber: after the reading task, if
//!   it is another, has been awaited; and before the client's `deinit`.
//!   The `Subscriber` itself stays where it is until then.
//! - One task at a time calls `next`. In safe builds, a second task that
//!   calls it meanwhile panics, and so does the client's `deinit` with a
//!   subscriber left.
//!
//! On Linux and macOS the cut wakes a `next` that waits at once. On
//! Windows a shutdown of a socket by its own side does not end a read that
//! waits on it: with zio, `next` returns at its next PING, within
//! `idle_ping`; with an `Io` that cannot time a read, such as std's on
//! Windows, the read waits in a task of its own, and the cut cancels it at
//! once.

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
/// The subscriber's state, in the heap, where the client reaches it, until
/// `deinit` frees it.
state: *subscription.State,
/// Held by `next` while it runs: `close` from another task waits for it.
running: Io.Mutex = .init,
/// Set by the first `close`.
closing: std.atomic.Value(bool) = .init(false),
/// Set once the first `close` is done: a second one waits for it.
closed: Io.Event = .unset,
/// What went wrong in the last `next`.
details: Diagnostics = .{},
/// In safe builds: set while `next` runs, so that a second task that
/// calls meanwhile panics.
busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},

/// A message of a channel.
pub const Message = struct {
    /// The channel it was published to.
    channel: []const u8,
    /// What was published, byte for byte.
    payload: []const u8,
    /// The pattern it came by; null for a channel of `channels`.
    pattern: ?[]const u8 = null,
};

/// The next message, which lives until the next call, even when another
/// task closes the subscriber meanwhile; null once the subscriber is
/// closed, by its `close` or the client's. It waits as long as it takes,
/// sending PING
/// after `idle_ping` of silence. What went wrong goes to `diagnostics()`;
/// after an error the subscriber is done with, and `next` is
/// `error.Closed`.
pub fn next(sub: *Subscriber, io: Io) Error!?Message {
    sub.enter();
    defer sub.leave();
    sub.running.lockUncancelable(io);
    defer sub.running.unlock(io);
    const state = sub.state;
    calls.checkUse(sub.client, io);
    const d = &sub.details;
    d.* = .{};
    if (state.isEnding()) return null;
    if (state.failed) return calls.fail(d, null, error.Closed, "the subscriber lost its connection to an error before: close it, and subscribe again", .{});
    return state.receive(io, d) catch |err| {
        // A close cut the stream: the end, not an error.
        if (state.isEnding()) return null;
        state.fail(io);
        return err;
    };
}

/// The details of the error of the last `next`.
pub fn diagnostics(sub: *const Subscriber) *const Diagnostics {
    return &sub.details;
}

/// Closes the subscriber from any task: it cuts the connection, so that a
/// `next` that waits in another task returns null, and so does every later
/// one; it waits for that `next`, and closes the connection. It frees
/// nothing: a message that the reading task holds stays as it came until
/// its next `next`, and `deinit` frees the subscriber. A second call
/// returns once the first is done.
pub fn close(sub: *Subscriber, io: Io) void {
    if (sub.closing.swap(true, .acq_rel)) {
        sub.closed.waitUncancelable(io);
        return;
    }
    const subscribers = &sub.client.subscribers;
    subscribers.end(io, sub.state);
    // The cut ended the wait of a `next` in another task.
    sub.running.lockUncancelable(io);
    sub.running.unlock(io);
    if (subscribers.disconnect(io, sub.state)) |conn| conn.destroy();
    sub.closed.set(io);
}

/// Closes the subscriber, if `close` has not, and frees it, the message of
/// the last `next` with it. Call it once no task reads the subscriber any
/// more: after the reading task, if it is another, has been awaited. The
/// subscriber is invalid after it.
pub fn deinit(sub: *Subscriber) void {
    const io = sub.client.io;
    sub.close(io);
    sub.client.subscribers.remove(io, sub.state);
    sub.state.destroy();
    sub.* = undefined;
}

/// In safe builds: a call while another task's runs panics.
fn enter(sub: *Subscriber) void {
    if (std.debug.runtime_safety and sub.busy.swap(true, .acquire)) {
        @panic("zefir-redis: a Subscriber used by two tasks at once: one task at a time calls next");
    }
}

fn leave(sub: *Subscriber) void {
    if (std.debug.runtime_safety) sub.busy.store(false, .release);
}
