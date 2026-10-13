//! Client options. Only `servers` has no default:
//!
//! ```zig
//! const options: nats.Options = .{
//!     .servers = &.{ "nats://10.0.0.1:4222", "nats://10.0.0.2:4222" },
//!     .name = "orders-service",
//!     .auth = .{ .user_password = .{ .username = "orders", .password = password } },
//! };
//! ```
//!
//! The client checks the options before it connects and keeps its own copy,
//! so the strings may be freed once the client is created.

const std = @import("std");
const Duration = std.Io.Duration;
const ServerAddress = @import("ServerAddress.zig");
const encoder = @import("protocol/encoder.zig");
const Options = @This();

/// `nats://host:port`, `host:port` or `[::1]:4222`; the port defaults to
/// 4222. Several servers are alternatives for failover, not a pool: the
/// client keeps one connection.
servers: []const []const u8,
/// The connection name the server shows in its monitoring.
name: ?[]const u8 = null,
/// The credentials sent in CONNECT.
auth: Auth = .none,
/// One attempt on one server: DNS, TCP and the INFO, CONNECT, PONG exchange.
/// On `std.Io.Threaded` under macOS, DNS is a blocking `getaddrinfo` that
/// cancellation may not stop: then an attempt, and a `close()` during it,
/// can take as long as the resolver.
connect_timeout: Duration = .fromSeconds(5),
/// How often the client PINGs the server to check that the connection is
/// alive.
ping_interval: Duration = .fromSeconds(30),
/// PINGs left unanswered before the connection counts as dead.
max_outstanding_pings: u8 = 2,
/// Do not deliver this client's own messages to its subscriptions.
no_echo: bool = false,
/// A request that reaches no subscriber fails at once with NoResponders.
no_responders: bool = true,
/// The server confirms every operation with +OK; for debugging only.
verbose: bool = false,
/// The server checks subjects more strictly.
pedantic: bool = false,
/// Try the servers in random order, so that clients spread over a cluster.
/// Not yet: this version tries them in the given order, and random order
/// comes with the pool of servers.
randomize_servers: bool = true,
/// Use only `servers`, not the servers the cluster announces.
ignore_discovered_servers: bool = false,
/// `connect()` returns at once and keeps trying in the background.
retry_initial_connect: bool = false,
/// What happens after the connection is lost.
reconnect: ReconnectOptions = .{},
/// Bounds on what the client holds in memory.
limits: Limits = .{},

pub const Auth = union(enum) {
    none,
    /// Sent in plaintext: use it only on a trusted network.
    user_password: UserPassword,

    pub const UserPassword = struct {
        username: []const u8,
        password: []const u8,
    };
};

pub const ReconnectOptions = struct {
    /// Reconnect after the connection is lost; when false, the client closes.
    enabled: bool = true,
    /// Failed attempts in a row before the client gives up; null: never.
    max_attempts: ?u32 = null,
    /// The first attempt is immediate; then the delay doubles from
    /// `min_delay` up to `max_delay`.
    min_delay: Duration = .fromMilliseconds(500),
    max_delay: Duration = .fromSeconds(10),
    /// A random part in every delay, so that clients do not reconnect in step.
    jitter: bool = true,
    /// Publishes kept while reconnecting and sent once connected; with 0
    /// they fail at once with Disconnected. Nothing is ever sent twice.
    buffer_bytes: usize = 8 * 1024 * 1024,
    /// Stop after a server rejects the credentials twice in a row.
    abort_on_auth_error: bool = true,
};

pub const Limits = struct {
    /// Frames waiting to be written: publish waits while the queue holds
    /// this many bytes or more, then queues its frame whole.
    outbound_bytes: usize = 8 * 1024 * 1024,
    /// Messages a subscription holds before its overflow policy drops some.
    subscription_messages: u32 = 1024,
    /// Bytes a subscription holds before its overflow policy drops messages;
    /// a message larger than this on its own is dropped as it comes.
    subscription_bytes: usize = 8 * 1024 * 1024,
    /// Requests waiting for a reply at once; more fail with
    /// TooManyPendingRequests.
    max_pending_requests: u32 = 65_536,
    /// Subscriptions at once, each until its `deinit()`; more fail with
    /// TooManySubscriptions.
    max_subscriptions: u32 = 65_536,
    /// The server's `max_control_line`: the longest arguments of a protocol
    /// line, such as a subject with its reply-to. Messages the server sends
    /// may be a few bytes longer, INFO and -ERR up to 64 KiB. Raise it
    /// together with the server's setting. It must hold this client's
    /// CONNECT, which the server checks against the same limit.
    max_control_line_bytes: u32 = 4096,
    /// The largest message accepted, headers included; larger ones are
    /// read past, dropped and counted.
    max_inbound_frame_bytes: u32 = 64 * 1024 * 1024,
    /// The largest header block accepted; messages with a larger one are
    /// read past, dropped and counted.
    max_header_bytes: u32 = 64 * 1024,
    /// Events kept for `nextEvent()`; more are dropped and counted.
    max_event_queue: u32 = 1024,
};

pub const Error = error{InvalidOptions};

/// The longest CONNECT JSON a server accepts by default (its `max_control_line`).
pub const max_connect_json = 4096;
/// Servers given and discovered, together.
pub const max_servers = 64;
/// The largest `limits.max_control_line_bytes`: the read buffer holds the
/// longest line the server may send.
pub const max_control_line_limit = 64 * 1024;

/// Checks every option; nothing touches the network.
pub fn validate(options: Options) Error!void {
    if (options.servers.len == 0 or options.servers.len > max_servers) return error.InvalidOptions;
    for (options.servers) |url| {
        _ = ServerAddress.parse(url) catch return error.InvalidOptions;
    }
    if (options.name) |name| {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidOptions;
    }
    switch (options.auth) {
        .none => {},
        .user_password => |credentials| {
            for ([_][]const u8{ credentials.username, credentials.password }) |text| {
                if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidOptions;
            }
        },
    }
    if (options.connect_timeout.nanoseconds <= 0 or options.ping_interval.nanoseconds <= 0) return error.InvalidOptions;
    if (options.max_outstanding_pings == 0) return error.InvalidOptions;

    const reconnect = options.reconnect;
    if (reconnect.min_delay.nanoseconds <= 0) return error.InvalidOptions;
    if (reconnect.max_delay.nanoseconds < reconnect.min_delay.nanoseconds) return error.InvalidOptions;
    if (reconnect.max_attempts == 0) return error.InvalidOptions;
    if (options.retry_initial_connect and !reconnect.enabled) return error.InvalidOptions;

    const limits = options.limits;
    if (limits.outbound_bytes == 0 or limits.subscription_messages == 0 or limits.subscription_bytes == 0 or
        limits.max_pending_requests == 0 or limits.max_subscriptions == 0 or limits.max_inbound_frame_bytes == 0 or
        limits.max_header_bytes == 0 or limits.max_event_queue == 0) return error.InvalidOptions;
    if (limits.max_control_line_bytes == 0 or limits.max_control_line_bytes > max_control_line_limit) return error.InvalidOptions;
    if (limits.max_header_bytes > limits.max_inbound_frame_bytes) return error.InvalidOptions;

    // The server checks CONNECT against its control line limit too.
    const connect_len = longestConnectJson(options);
    if (connect_len > max_connect_json or connect_len > limits.max_control_line_bytes) return error.InvalidOptions;
}

/// The CONNECT JSON as long as it can get: as if the server supported headers.
fn longestConnectJson(options: Options) usize {
    return encoder.connectJsonLen(.{
        .verbose = options.verbose,
        .pedantic = options.pedantic,
        .echo = !options.no_echo,
        .headers = true,
        .no_responders = options.no_responders,
        .name = options.name,
        .user = switch (options.auth) {
            .none => null,
            .user_password => |credentials| credentials.username,
        },
        .pass = switch (options.auth) {
            .none => null,
            .user_password => |credentials| credentials.password,
        },
    });
}

const testing = std.testing;
const one_server: []const []const u8 = &.{"nats://127.0.0.1:4222"};

fn expectInvalid(options: Options) !void {
    try testing.expectError(error.InvalidOptions, validate(options));
}

test "defaults are valid and match the spec" {
    const options: Options = .{ .servers = one_server };
    try validate(options);
    try testing.expectEqual(5, options.connect_timeout.toSeconds());
    try testing.expectEqual(30, options.ping_interval.toSeconds());
    try testing.expectEqual(500, options.reconnect.min_delay.toMilliseconds());
    try testing.expectEqual(8 * 1024 * 1024, options.reconnect.buffer_bytes);
    try testing.expectEqual(4096, options.limits.max_control_line_bytes);
}

test "servers: at least one, at most 64, every one parses" {
    try expectInvalid(.{ .servers = &.{} });
    try expectInvalid(.{ .servers = &.{ "nats://a:4222", "tls://b:4222" } });
    const many: [max_servers + 1][]const u8 = @splat("a:4222");
    try validate(.{ .servers = many[0..max_servers] });
    try expectInvalid(.{ .servers = &many });
}

test "name and credentials" {
    try expectInvalid(.{ .servers = one_server, .name = "" });
    try expectInvalid(.{ .servers = one_server, .name = "bad\xff" });
    try validate(.{ .servers = one_server, .name = "сервис" });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "", .password = "p" } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "" } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "\xc3" } } });
    try validate(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "p\"w\\d" } } });
}

test "durations and reconnect" {
    try expectInvalid(.{ .servers = one_server, .connect_timeout = .zero });
    try expectInvalid(.{ .servers = one_server, .ping_interval = .fromSeconds(-1) });
    try expectInvalid(.{ .servers = one_server, .max_outstanding_pings = 0 });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .min_delay = .zero } });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .min_delay = .fromSeconds(2), .max_delay = .fromSeconds(1) } });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .max_attempts = 0 } });
    try expectInvalid(.{ .servers = one_server, .retry_initial_connect = true, .reconnect = .{ .enabled = false } });
    try validate(.{ .servers = one_server, .retry_initial_connect = true });
    try validate(.{ .servers = one_server, .reconnect = .{ .buffer_bytes = 0 } });
}

test "limits" {
    for ([_]Limits{
        .{ .outbound_bytes = 0 },                                  .{ .subscription_messages = 0 },                                .{ .subscription_bytes = 0 },
        .{ .max_pending_requests = 0 },                            .{ .max_subscriptions = 0 },                                    .{ .max_inbound_frame_bytes = 0 },
        .{ .max_header_bytes = 0 },                                .{ .max_event_queue = 0 },                                      .{ .max_control_line_bytes = 0 },
        .{ .max_control_line_bytes = max_control_line_limit + 1 }, .{ .max_header_bytes = 1024, .max_inbound_frame_bytes = 1023 },
    }) |limits| {
        try expectInvalid(.{ .servers = one_server, .limits = limits });
    }
    try validate(.{ .servers = one_server, .limits = .{ .max_control_line_bytes = max_control_line_limit } });
}

test "CONNECT must fit in 4096 bytes after JSON escaping" {
    // The JSON with a one-letter name, minus that letter: what the name adds to.
    const base = encoder.connectJsonLen(.{ .headers = true, .no_responders = true, .name = "x" }) - 1;
    const names: [max_connect_json]u8 = @splat('x');
    try validate(.{ .servers = one_server, .name = names[0 .. max_connect_json - base] });
    try expectInvalid(.{ .servers = one_server, .name = names[0 .. max_connect_json - base + 1] });

    // An escaped quote takes two bytes in the JSON.
    const quotes: [2100]u8 = @splat('"');
    try validate(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = names[0..2100] } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = &quotes } } });
}

test "the control line limit must hold this client's CONNECT" {
    // The server checks CONNECT against its max_control_line too.
    const connect_len = longestConnectJson(.{ .servers = one_server, .name = "orders" });
    const fits: u32 = @intCast(connect_len);
    try validate(.{ .servers = one_server, .name = "orders", .limits = .{ .max_control_line_bytes = fits } });
    try expectInvalid(.{ .servers = one_server, .name = "orders", .limits = .{ .max_control_line_bytes = fits - 1 } });
    try expectInvalid(.{ .servers = one_server, .limits = .{ .max_control_line_bytes = 1 } });
}
