//! `rpc.transport`: the types a transport works with, besides the
//! interfaces `rpc.ClientTransport` and `rpc.ServerTransport`.

const std = @import("std");
const core = @import("core");
const model = @import("model.zig");

/// Where a server transport delivers incoming calls; the engine implements
/// it.
pub const Dispatcher = @import("Dispatcher.zig");
/// One admitted call; the engine implements it.
pub const Incoming = @import("Incoming.zig");
/// How the engine answers one call; the transport implements it.
pub const Reply = @import("Reply.zig");
/// Slots for calls that wait for their responses, for transports that
/// match responses to requests themselves.
pub const Pending = @import("Pending.zig");

/// A request that the client engine hands to `rpc.ClientTransport.call`.
pub const Request = struct {
    route: model.Route,
    /// 16 random bytes from the engine, for logs and tracing; not an
    /// idempotency key.
    request_id: [16]u8,
    /// The codec of the body; "json" in v1.
    codec: []const u8,
    /// The caller's context. The engine always sets `ctx.deadline`: the
    /// transport sends the budget left right before sending and waits for the
    /// response no longer than the deadline. `ctx.trace` is for the
    /// transport's own logs and spans; the engine has already put the trace
    /// into `metadata`. `ctx.cancellation` is not an alarm: the transport
    /// does not poll it, the cancelation of the caller's task ends the wait.
    ctx: core.Context,
    /// With the engine's reserved keys: traceparent, tracestate,
    /// authorization, zefir-correlation-id. The transport carries them as
    /// ordinary pairs.
    metadata: []const model.Metadata.Entry,
    body: []const u8,
};

/// The head of an incoming request: the transport has read it, the body not
/// yet.
pub const RequestHead = struct {
    route: model.Route,
    /// When the wire has none (a NATS request from a foreign client), the
    /// transport makes up 16 random bytes itself.
    request_id: [16]u8,
    codec: []const u8,
    /// The budget the client sent; null when the transport does not carry
    /// one.
    timeout: ?std.Io.Duration,
    /// When the transport finished reading the head, on the
    /// `std.Io.Clock.awake` clock. The server's deadline is
    /// `received_at + timeout`.
    received_at: std.Io.Timestamp,
    metadata: []const model.Metadata.Entry,
    /// Who sent the request, for logs only, never for authorization.
    peer: Peer = .none,
};

/// The sender of a request, as the transport knows it.
pub const Peer = union(enum) {
    none,
    /// A direct transport: the address of the other side; behind a load
    /// balancer, the balancer's address.
    ip: std.Io.net.IpAddress,
    /// Free text of the transport, such as the name of a NATS client.
    name: []const u8,
};

/// What a transport can do. The defaults are the most cautious answers.
pub const Info = struct {
    /// A short name for logs and metrics: "nats", "memory", "amqp".
    name: []const u8,
    /// A client's cancelation or timeout reaches the server and stops the
    /// handler.
    propagates_cancellation: bool = false,
    /// The transport can tell the client that a call surely did not run (no
    /// server, the server drains, NATS no responders): that is
    /// `error.Unavailable`. Without it, such calls end in `error.Timeout`.
    reports_unprocessed: bool = false,
    /// The client sees a link that breaks in the middle of a call at once
    /// (`error.ConnectionLost`), not at the deadline. Direct transports do;
    /// NATS does not, with the broker in between.
    reports_connection_loss: bool = false,
    /// How many times one request may run on the server.
    delivery: Delivery = .at_most_once,
    /// The largest body, with empty metadata, that the transport can carry
    /// now; null when only the rpc limits apply. It may change after a
    /// reconnect (NATS max_payload).
    max_body_bytes: ?usize = null,
};

/// How many times one request may run on the server. Later releases may add
/// values, so a `switch` over it needs an `else` branch.
pub const Delivery = enum(u8) { at_most_once, at_least_once, _ };

/// Details of an error, for logs. The transport fills them in when the caller
/// passes a pointer. Nothing is allocated: the message lives in a fixed
/// buffer.
pub const Diagnostics = struct {
    /// Where the error happened. Later releases may add values, so a `switch`
    /// over it needs an `else` branch.
    pub const Phase = enum(u8) { connect, handshake, send, wait, receive, _ };

    phase: ?Phase = null,
    /// The transport library's own error, for logs, not for logic.
    cause: ?anyerror = null,
    buffer: [256]u8 = undefined,
    len: u16 = 0,

    /// The message of the last `set`.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.buffer[0..d.len];
    }

    /// Records the phase, the cause and a formatted message. A message
    /// longer than the buffer is cut short, before a UTF-8 character that
    /// does not fit whole.
    pub fn set(d: *Diagnostics, phase: Phase, cause: ?anyerror, comptime fmt: []const u8, args: anytype) void {
        d.phase = phase;
        d.cause = cause;
        var w: std.Io.Writer = .fixed(&d.buffer);
        w.print(fmt, args) catch {
            w.end = wholeUtf8Prefix(d.buffer[0..w.end]);
        };
        d.len = @intCast(w.end);
    }
};

/// The length of `bytes` without a UTF-8 character cut at the end. Bytes that
/// are not UTF-8 stay as they are.
fn wholeUtf8Prefix(bytes: []const u8) usize {
    // The last character starts at most 3 bytes before the end.
    var start = bytes.len;
    while (start > 0 and bytes.len - start < 4) {
        start -= 1;
        const byte = bytes[start];
        if (byte & 0xC0 == 0x80) continue; // a continuation byte
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return bytes.len;
        return if (bytes.len - start < len) start else bytes.len;
    }
    return bytes.len;
}

test "diagnostics keep the phase, the cause and the message" {
    var d: Diagnostics = .{};
    try std.testing.expectEqualStrings("", d.message());
    d.set(.send, error.BrokenPipe, "wrote {d} of {d} bytes to {s}", .{ 12, 40, "nats" });
    try std.testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
    try std.testing.expectEqual(error.BrokenPipe, d.cause.?);
    try std.testing.expectEqualStrings("wrote 12 of 40 bytes to nats", d.message());

    // A later set replaces all three.
    d.set(.wait, null, "no reply", .{});
    try std.testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
    try std.testing.expectEqual(@as(?anyerror, null), d.cause);
    try std.testing.expectEqualStrings("no reply", d.message());
}

test "diagnostics cut a long message at 256 bytes" {
    var d: Diagnostics = .{};
    const long: [300]u8 = @splat('a');
    d.set(.receive, null, "{s}", .{&long});
    try std.testing.expectEqualStrings(long[0..256], d.message());

    // A character that does not fit whole is dropped whole.
    const cut = @as([255]u8, @splat('b')) ++ "é!".*;
    d.set(.receive, null, "{s}", .{&cut});
    try std.testing.expectEqualStrings(cut[0..255], d.message());
    const three = @as([254]u8, @splat('c')) ++ "€".*;
    d.set(.receive, null, "{s}", .{&three});
    try std.testing.expectEqualStrings(three[0..254], d.message());
    // A character that ends right at the end stays.
    const exact = @as([254]u8, @splat('d')) ++ "é".*;
    d.set(.receive, null, "{s}x", .{&exact});
    try std.testing.expectEqualStrings(&exact, d.message());
}

test "delivery and diagnostics phase are open to new values" {
    inline for (.{ Delivery, Diagnostics.Phase }) |E| {
        try std.testing.expectEqual(std.lang.Type.Enum.Mode.nonexhaustive, @typeInfo(E).@"enum".mode);
    }
}

test "info, request head and peer default to the cautious answers" {
    const info: Info = .{ .name = "x" };
    try std.testing.expect(!info.propagates_cancellation);
    try std.testing.expect(!info.reports_unprocessed);
    try std.testing.expect(!info.reports_connection_loss);
    try std.testing.expectEqual(Delivery.at_most_once, info.delivery);
    try std.testing.expectEqual(@as(?usize, null), info.max_body_bytes);

    const head: RequestHead = .{
        .route = .{ .service = "users", .version = 1, .method = "getUser" },
        .request_id = @splat(0),
        .codec = "json",
        .timeout = null,
        .received_at = .zero,
        .metadata = &.{},
    };
    try std.testing.expect(head.peer == .none);
}
