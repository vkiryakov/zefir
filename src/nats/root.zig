//! zefir-nats — a Core NATS client written against `std.Io` only: it runs
//! on any `std.Io` implementation with real concurrency, and zio is the one
//! meant for production. It speaks plaintext TCP with no auth or with user
//! and password; TLS and JetStream are not part of this version.
//!
//! Work in progress: the client connects, keeps the connection alive with
//! PINGs, publishes, subscribes, flushes and measures the round trip.
//! Request/reply and reconnect come next; until then a lost connection
//! closes the client and ends its subscriptions.

const std = @import("std");

pub const Options = @import("Options.zig");
pub const Auth = Options.Auth;
pub const ReconnectOptions = Options.ReconnectOptions;
pub const Limits = Options.Limits;
pub const ServerAddress = @import("ServerAddress.zig");
pub const ServerInfo = @import("ServerInfo.zig");
pub const Headers = @import("Headers.zig");
pub const Header = Headers.Header;
pub const Client = @import("Client.zig");
pub const State = Client.State;
pub const FlushOptions = Client.FlushOptions;
pub const Message = @import("Message.zig");
pub const PublishMessage = Message.PublishMessage;
pub const Subscription = @import("Subscription.zig");
pub const SubscribeOptions = Subscription.Options;
pub const OverflowPolicy = Subscription.OverflowPolicy;
pub const ReceiveOptions = Subscription.ReceiveOptions;
pub const PendingCounts = Subscription.PendingCounts;
pub const SubscriptionStats = Subscription.Stats;

/// Every error the client returns, apart from those of `std.Io` that pass
/// through unchanged, such as network errors. Each function lists the ones
/// it can return.
pub const Error = error{
    /// The options break a rule; checked before anything connects.
    InvalidOptions,
    InvalidSubject,
    /// A header name or value that cannot be sent.
    InvalidHeader,
    /// Headers and payload together exceed the server's `max_payload`.
    PayloadTooLarge,
    /// The reconnect buffer is full.
    BufferFull,
    /// A subscription dropped messages and closed.
    SlowConsumer,
    /// The server refused the subject.
    PermissionDenied,
    /// Another task already waits for the next item.
    ConcurrentReceive,
    /// The message to answer has no reply subject.
    NoReplySubject,
    TooManySubscriptions,
    TooManyPendingRequests,
    Timeout,
    /// No one subscribes to the subject of the request.
    NoResponders,
    /// The task was canceled through `std.Io`.
    Canceled,
    /// The client has no connection at the moment.
    Disconnected,
    /// The client is closed.
    ConnectionClosed,
    /// The client is draining and takes no new work.
    ConnectionDraining,
    /// The server refused the credentials.
    AuthenticationFailed,
    /// The server wants TLS, which this client does not do.
    UnsupportedSecurityFeature,
    /// The server cannot do what was asked, such as headers or no-echo.
    UnsupportedFeature,
    /// The server broke the protocol, or reports that this client did.
    ProtocolError,
    /// The `std.Io` cannot run the client's tasks.
    ConcurrencyUnavailable,
    OutOfMemory,
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("Options.zig");
    _ = @import("ServerAddress.zig");
    _ = @import("ServerInfo.zig");
    _ = @import("Headers.zig");
    _ = @import("Message.zig");
    _ = @import("engine/incoming.zig");
    _ = @import("Subscription.zig");
    _ = @import("engine/MessageQueue.zig");
    _ = @import("engine/Registry.zig");
    _ = @import("engine/Inbox.zig");
    _ = @import("protocol/subject.zig");
    _ = @import("protocol/encoder.zig");
    _ = @import("protocol/Parser.zig");
    _ = @import("protocol/server_error.zig");
    _ = @import("protocol/golden.zig");
    _ = @import("protocol/fuzz.zig");
    _ = @import("engine/OwnedOptions.zig");
    _ = @import("engine/time.zig");
    _ = @import("engine/Broadcast.zig");
    _ = @import("engine/queue.zig");
    _ = @import("engine/connect.zig");
    _ = @import("engine/Outbound.zig");
    _ = @import("engine/Connection.zig");
    _ = @import("engine/manager.zig");
    _ = @import("Client.zig");
    _ = @import("testing/client_tests.zig");
    _ = @import("testing/messaging_tests.zig");
}

/// The errors of `std.Io` that the client passes through unchanged.
const IoErrors = std.Io.net.IpAddress.ConnectError || std.Io.net.HostName.ConnectError ||
    std.Io.net.HostName.ValidateError || std.Io.net.Ip6Address.ResolveError ||
    std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error;

fn isIn(comptime Set: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Set).error_set.error_names.?) |member| {
        if (std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

test "every error of the module's functions is in nats.Error or comes from std.Io" {
    inline for (.{
        Client.InitError,    Client.ConnectError,      Client.FlushError,      Client.ServerInfoError,
        Options.Error,       ServerAddress.ParseError, ServerInfo.ParseError,  Headers.ValidateError,
        Client.PublishError, Client.SubscribeError,    Subscription.NextError, Subscription.UnsubscribeError,
    }) |Set| {
        inline for (comptime @typeInfo(Set).error_set.error_names.?) |name| {
            if (comptime !isIn(Error, name) and !isIn(IoErrors, name)) {
                std.debug.print("{s} is neither in nats.Error nor from std.Io\n", .{name});
                return error.TestUnexpectedError;
            }
        }
    }
}
