//! The responses to one `requestMany`, in the order they came: scatter and
//! gather. The stream ends at the request's deadline or after
//! `max_responses` responses, whichever comes first; to stop earlier, on a
//! condition of your own, break out of the loop. The client owns it;
//! `deinit()` ends it and frees it, and comes before the client's own
//! `deinit()`.
//!
//! ```zig
//! const responses = try client.requestMany("inventory.count", "sku-42", .{ .max_responses = 8 });
//! defer responses.deinit();
//! while (true) {
//!     var msg = (try responses.next(.{})) orelse break;
//!     defer msg.deinit();
//!     total += try std.fmt.parseInt(u32, msg.payload, 10);
//! }
//! ```
//!
//! One task at a time waits in `next()`; any task may `cancel()`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const Message = @import("Message.zig");
const Subscription = @import("Subscription.zig");
const MessageQueue = @import("engine/MessageQueue.zig");
const time = @import("engine/time.zig");
const Responses = @This();

client: *Client,
/// Its id in the client's inbox.
id: u64,
/// The stream ends here, whatever came.
deadline: Io.Clock.Timestamp,
/// The responses that wait to be taken. Internal: the client's reader
/// fills it; take responses with `next()`. Tests may ask it
/// `isReceiving()`.
messages: MessageQueue,

pub const NextError = error{
    /// No response came within `options.timeout`; the stream goes on.
    Timeout,
    /// The task was canceled through `std.Io`.
    Canceled,
    /// Another task waits for the next response already.
    ConcurrentReceive,
    /// No one subscribes to the subject of the request.
    NoResponders,
    /// The connection was lost; the responses that came before it come
    /// out first.
    Disconnected,
    /// The client is closed.
    ConnectionClosed,
};

/// The next response, oldest first; free it with its `deinit()`. Waits for
/// one until `options.timeout`, never past the deadline of the request.
/// Null once the stream has ended: at the deadline, after `max_responses`
/// responses, or after `cancel()`; the responses that came before come out
/// first. One task at a time may wait.
pub fn next(r: *Responses, options: Subscription.ReceiveOptions) NextError!?Message {
    const io = r.client.io;
    const wanted = time.deadline(io, options.timeout);
    const until = if (wanted) |w| if (w.raw.nanoseconds < r.deadline.raw.nanoseconds) w else r.deadline else r.deadline;
    while (true) {
        const response = r.messages.next(io, time.until(until)) catch |err| switch (err) {
            error.Timeout => {
                if (!time.expired(io, r.deadline)) return error.Timeout;
                // The deadline: what came comes out, then null.
                r.stop(false);
                continue;
            },
            // A stream drops the newest when full and is never refused.
            error.SlowConsumer, error.PermissionDenied => return error.ConnectionClosed,
            else => |e| return e,
        };
        // Over: responses that still come are late.
        if (response == null) r.client.inbox.remove(io, r.id);
        return response;
    }
}

/// Ends the stream now, from any task: what waits is dropped, `next()`
/// returns null, and responses that still come count as late.
pub fn cancel(r: *Responses) void {
    r.stop(true);
}

/// Takes the stream out of the inbox, then ends it, dropping what waits
/// when `discard`.
fn stop(r: *Responses, discard: bool) void {
    const io = r.client.io;
    r.client.inbox.remove(io, r.id);
    _ = r.messages.end(io, .finished, discard);
}

/// Ends the stream and frees it, with the responses it still holds. No
/// task may wait in `next()` meanwhile.
pub fn deinit(r: *Responses) void {
    r.client.inbox.remove(r.client.io, r.id);
    destroy(r.client.gpa, r);
}

/// A stream for a request of `client` that ends at `deadline`, with room
/// for `limits`; it gets its id when it joins the inbox.
pub fn create(gpa: Allocator, client: *Client, deadline: Io.Clock.Timestamp, limits: MessageQueue.Limits) Allocator.Error!*Responses {
    const r = try gpa.create(Responses);
    r.* = .{
        .client = client,
        .id = 0,
        .deadline = deadline,
        .messages = .init(gpa, limits, .drop_newest, limits.messages),
    };
    return r;
}

/// Frees `r` and the responses it holds; it must have left the inbox.
pub fn destroy(gpa: Allocator, r: *Responses) void {
    r.messages.deinit();
    gpa.destroy(r);
}

/// How many bytes a response may take; null when the stream takes no more.
pub fn accepts(r: *Responses, io: Io) ?usize {
    if (time.expired(io, r.deadline) or !r.messages.isOpen(io)) return null;
    return r.messages.limits.bytes;
}
