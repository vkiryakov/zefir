//! A client of a NATS server.
//!
//! ```zig
//! var client: nats.Client = try .init(gpa, io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
//! defer client.deinit();
//! try client.connect();
//! try client.flush(.{});
//! ```
//!
//! `connect()` starts the client's tasks, which keep a pointer to it: from
//! then on the client must stay where it is, so do not move or copy it.
//! Every method may be called from any task at the same time. The
//! allocator must be thread-safe. The `io` needs real concurrency, such as
//! `std.Io.Threaded` or zio; without it `connect()` fails with
//! ConcurrencyUnavailable.
//!
//! In this version a lost connection closes the client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Options = @import("Options.zig");
const ServerAddress = @import("ServerAddress.zig");
const ServerInfo = @import("ServerInfo.zig");
const Parser = @import("protocol/Parser.zig");
const OwnedOptions = @import("engine/OwnedOptions.zig");
const Outbound = @import("engine/Outbound.zig");
const Connection = @import("engine/Connection.zig");
const dialer = @import("engine/connect.zig");
const manager = @import("engine/manager.zig");
const time = @import("engine/time.zig");
const log = std.log.scoped(.nats);
const Client = @This();

gpa: Allocator,
io: Io,
options: OwnedOptions,
/// The read buffer of every connection: the longest line the server may
/// send fits in it.
read_buffer: []u8,
parser_limits: Parser.Limits,
outbound: Outbound,
/// The manager task.
tasks: Io.Group = .init,
/// The reader and writer of the current connection.
connection_tasks: Io.Group = .init,
/// The current connection; only the manager opens and closes it.
connection: Connection = undefined,

/// Held while connect, close and deinit start or stop the manager.
lifecycle: Io.Mutex = .init,
/// Guards the fields below.
mutex: Io.Mutex = .init,
/// Broadcast on every change of the fields below.
changed: Io.Condition = .init,
status: State = .disconnected,
/// Why the current connection must end; the manager acts on it.
exit: ?manager.Exit = null,
/// The attempt to connect in progress, for `close()` to stop.
attempt: ?*manager.AttemptState = null,
/// Why the first connection failed, for `connect()` to return.
connect_error: ?ConnectError = null,
/// The server of the current connection.
server: ?ServerAddress = null,
/// The JSON of the latest INFO of the current connection.
info_json: ?[]u8 = null,
/// `deinit` has run.
freed: bool = false,

/// Where the client is in its life.
pub const State = enum {
    /// `connect()` has not been called yet.
    disconnected,
    /// `connect()` is opening the first connection.
    connecting,
    connected,
    /// The connection was lost and a new one is being opened.
    reconnecting,
    /// Finishing its work before it closes.
    draining,
    /// Closed for good.
    closed,
};

pub const InitError = Options.Error || Allocator.Error;

pub const ConnectError = error{
    /// The client is closed: `close()` was called, or connecting failed.
    ConnectionClosed,
    /// The `io` cannot run the client's tasks.
    ConcurrencyUnavailable,
} || dialer.DialError || Connection.HandshakeError;

pub const FlushError = error{
    /// Not connected yet.
    Disconnected,
    ConnectionClosed,
    Timeout,
    Canceled,
    OutOfMemory,
};

pub const ServerInfoError = error{ OutOfMemory, ProtocolError };

pub const FlushOptions = struct {
    /// How long to wait for the server's PONG.
    timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
};

/// Checks `options` and copies them, so the caller may free its strings at
/// once. Nothing touches the network before `connect()`.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    var owned: OwnedOptions = try .init(gpa, options);
    errdefer owned.deinit(gpa);
    const parser_limits: Parser.Limits = .{ .max_control_line = owned.options.limits.max_control_line_bytes };
    return .{
        .gpa = gpa,
        .io = io,
        .options = owned,
        .read_buffer = try gpa.alloc(u8, Parser.bufferLen(parser_limits)),
        .parser_limits = parser_limits,
        .outbound = .init(gpa, owned.options.limits.outbound_bytes),
    };
}

/// Connects to the first of `servers` that takes the connection, one
/// attempt each, every attempt within `connect_timeout`. A failed connect
/// closes the client: create a new one to try again. A call made while
/// another one is connecting waits for that outcome; once the client is
/// connected, another call changes nothing.
pub fn connect(client: *Client) ConnectError!void {
    const io = client.io;
    {
        client.lifecycle.lockUncancelable(io);
        defer client.lifecycle.unlock(io);
        client.mutex.lockUncancelable(io);
        const status = client.status;
        if (status == .disconnected) client.status = .connecting;
        client.mutex.unlock(io);
        switch (status) {
            .disconnected => client.tasks.concurrent(io, manager.run, .{client}) catch |err| {
                manager.connectFailed(client, err);
                return err;
            },
            .connecting => {},
            .closed => return error.ConnectionClosed,
            .connected, .reconnecting, .draining => return,
        }
    }

    client.mutex.lockUncancelable(io);
    while (client.status == .connecting) {
        client.changed.wait(io, &client.mutex) catch |err| {
            // The caller gave up: the attempt stops and the client closes.
            client.mutex.unlock(io);
            client.close();
            return err;
        };
    }
    defer client.mutex.unlock(io);
    if (client.status == .connected) return;
    return client.connect_error orelse error.ConnectionClosed;
}

/// Waits until the server has processed everything this client sent
/// before: a PING goes out after it, and the server answers with PONG.
pub fn flush(client: *Client, options: FlushOptions) FlushError!void {
    _ = try client.ping(options.timeout);
}

/// How long a PING takes to come back as PONG.
pub fn rtt(client: *Client, options: FlushOptions) FlushError!Io.Duration {
    return client.ping(options.timeout);
}

fn ping(client: *Client, timeout: Io.Timeout) FlushError!Io.Duration {
    const io = client.io;
    const deadline = time.deadline(io, timeout);
    switch (client.state()) {
        .connected => {},
        .closed => return error.ConnectionClosed,
        .disconnected, .connecting, .reconnecting, .draining => return error.Disconnected,
    }
    const start = Io.Clock.awake.now(io);
    const number = client.outbound.putPing(io, .flush) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    client.outbound.waitPong(io, number, deadline) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.Timeout => return error.Timeout,
        error.Canceled => return error.Canceled,
    };
    return start.durationTo(Io.Clock.awake.now(io));
}

/// Closes the client at once: nothing still queued is sent, and every task
/// waiting in the client gets ConnectionClosed. For a careful stop, flush
/// first. Calling it again does nothing.
pub fn close(client: *Client) void {
    if (client.freed) return;
    const io = client.io;
    client.lifecycle.lockUncancelable(io);
    defer client.lifecycle.unlock(io);
    client.mutex.lockUncancelable(io);
    if (client.status != .closed) log.debug("closing the client", .{});
    client.status = .closed;
    if (client.exit == null) client.exit = .closed;
    // Under the lock: the attempt lives on the manager's stack until it is
    // untracked.
    if (client.attempt) |attempt| attempt.stop(io);
    client.changed.broadcast(io);
    client.mutex.unlock(io);
    client.outbound.close(io);
    // The manager closes its connection and returns.
    client.tasks.cancel(io);
}

/// Closes the client if needed and frees everything. Calling it again does
/// nothing. No other task may use the client any more.
pub fn deinit(client: *Client) void {
    if (client.freed) return;
    client.close();
    client.outbound.deinit();
    if (client.info_json) |json| client.gpa.free(json);
    client.gpa.free(client.read_buffer);
    client.options.deinit(client.gpa);
    client.freed = true;
}

pub fn state(client: *Client) State {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return client.status;
}

pub fn isConnected(client: *Client) bool {
    return client.state() == .connected;
}

/// The server of the current connection; null when not connected. The
/// result is a copy: its `host()` points into it, so keep the copy while
/// you use the host.
pub fn connectedServer(client: *Client) ?ServerAddress {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return if (client.status == .connected) client.server else null;
}

/// What the server of the current connection said about itself in its
/// latest INFO, parsed into memory from `gpa`: free it with `deinit()`.
/// Null when not connected.
pub fn serverInfo(client: *Client, gpa: Allocator) ServerInfoError!?std.json.Parsed(ServerInfo) {
    const json = copy: {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        if (client.status != .connected) return null;
        const json = client.info_json orelse return null;
        break :copy try gpa.dupe(u8, json);
    };
    defer gpa.free(json);
    return try ServerInfo.parse(gpa, json);
}

const testing = std.testing;
const one_server: []const []const u8 = &.{"nats://127.0.0.1:4222"};

test "init refuses bad options" {
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, testing.io, .{ .servers = &.{} }));
    try testing.expectError(error.InvalidOptions, Client.init(testing.allocator, testing.io, .{ .servers = &.{"tls://a"} }));
}

test "before connect the client has no server" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    defer client.deinit();
    try testing.expectEqual(.disconnected, client.state());
    try testing.expect(!client.isConnected());
    try testing.expect(client.connectedServer() == null);
    try testing.expect(try client.serverInfo(testing.allocator) == null);
    try testing.expectError(error.Disconnected, client.flush(.{}));
    try testing.expectError(error.Disconnected, client.rtt(.{}));
}

test "close before connect, connect after close, deinit twice" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = one_server });
    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expectError(error.ConnectionClosed, client.connect());
    try testing.expectError(error.ConnectionClosed, client.flush(.{}));
    client.close();
    client.deinit();
    client.deinit();
}

test "connect needs an io with concurrency" {
    var single: Io.Threaded = .init_single_threaded;
    var client: Client = try .init(testing.allocator, single.io(), .{ .servers = one_server });
    defer client.deinit();
    try testing.expectError(error.ConcurrencyUnavailable, client.connect());
    try testing.expectEqual(.closed, client.state());
}
