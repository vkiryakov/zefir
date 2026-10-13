//! A subscription: the messages published to its subject reach it in
//! order. The client owns it; `deinit()` ends it and frees it, and comes
//! before the client's own `deinit()`.
//!
//! ```zig
//! const sub = try client.subscribe("orders.*", .{ .queue = "workers" });
//! defer sub.deinit();
//! ```

const std = @import("std");
const Client = @import("Client.zig");
const MessageQueue = @import("engine/MessageQueue.zig");
const Registry = @import("engine/Registry.zig");
const log = std.log.scoped(.nats);
const Subscription = @This();

client: *Client,
/// Its id on the connection, from 1 up; the client never reuses one.
sid: u64,
/// The subject subscribed to, wildcards included.
subject: []const u8,
/// The queue group it joined, if any.
queue_group: ?[]const u8,
/// The messages that wait to be taken.
messages: MessageQueue,

pub const Options = struct {
    /// Join this queue group: the server gives each message to one member
    /// of the group.
    queue: ?[]const u8 = null,
    /// End the subscription after this many messages, at most 999 999 999;
    /// the server stops sending then.
    max_messages: ?u64 = null,
    /// How much may wait to be taken; more goes by `overflow`.
    pending: Pending = .{},
    overflow: OverflowPolicy = .drop_newest,

    pub const Pending = struct {
        /// Null: `limits.subscription_messages` of the client's options.
        messages: ?u32 = null,
        /// The bytes of the messages, subject and headers included; null:
        /// `limits.subscription_bytes` of the client's options.
        bytes: ?usize = null,
    };
};

/// What happens to a message that does not fit in the subscription.
pub const OverflowPolicy = enum {
    /// The new message is dropped.
    drop_newest,
    /// The oldest messages are dropped to make room for it.
    drop_oldest,
    /// The subscription ends: what it holds can still be taken, then
    /// SlowConsumer.
    close_subscription,
};

/// Ends the subscription and frees it, with the messages it still holds.
/// No task may wait for its messages meanwhile. The server is told to stop
/// sending, unless the subscription had ended already.
pub fn deinit(sub: *Subscription) void {
    const client = sub.client;
    const io = client.io;
    if (sub.messages.isOpen(io)) {
        Registry.queueUnsub(&client.outbound, io, sub.sid) catch |err| {
            log.debug("no UNSUB for subscription {d}: {t}", .{ sub.sid, err });
        };
    }
    client.subscriptions.unregister(io, sub.sid);
    Registry.destroy(client.gpa, sub);
}
