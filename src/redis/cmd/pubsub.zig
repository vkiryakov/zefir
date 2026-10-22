//! The pub/sub command of `redis.cmd`: PUBLISH of a message to the
//! subscribers of a channel. The message reaches those subscribed at that
//! moment, and no one keeps it: a subscriber that is away misses it, and a
//! queue that must not lose a message is a stream.
//!
//! ```zig
//! const got = try client.run(io, op, redis.cmd.publish("orders", order_json), .{});
//! ```

const command = @import("command.zig");

/// PUBLISH `channel` `message`: sends `message`, any bytes, to the
/// subscribers of `channel`; how many of them got it.
pub fn publish(channel: []const u8, message: []const u8) Publish {
    return .{ .args = .{ .channel = channel, .message = message } };
}

pub const Publish = command.Command("redis.cmd.publish", "PUBLISH", u64, struct { channel: []const u8, message: []const u8 });
