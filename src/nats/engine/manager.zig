//! The client's tasks. The manager opens the connection, starts its reader
//! and writer and sends heartbeat PINGs. When the connection must end, it
//! takes it down in order: the queues close and wake their waiters, the
//! socket is shut down, the reader and writer are canceled and awaited, and
//! only then does the socket close. In this version the client closes with
//! its connection.
//!
//! A task blocked on a socket is never left to cancellation alone: code a
//! task calls may swallow `error.Canceled` (std's stack capture in a Debug
//! allocator does), and on `std.Io.Threaded` the task's later syscalls then
//! cannot be interrupted. A shutdown of the socket wakes it either way.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("../Client.zig");
const ServerAddress = @import("../ServerAddress.zig");
const ServerInfo = @import("../ServerInfo.zig");
const server_error = @import("../protocol/server_error.zig");
const Connection = @import("Connection.zig");
const dialer = @import("connect.zig");
const time = @import("time.zig");
const log = std.log.scoped(.nats);

/// Why a connection ends.
pub const Exit = union(enum) {
    /// `close()`.
    closed,
    /// The server closed the connection.
    end_of_stream,
    /// The server left PINGs unanswered.
    stale,
    /// The server sent a `-ERR` after which it closes the connection.
    server_error: server_error.Kind,
    /// The server broke the protocol.
    protocol,
    /// Reading from the socket failed.
    read: Connection.ReadError,
    /// Writing to the socket failed.
    write: Connection.WriteError,
};

/// The manager task: from `connect()` until the client closes.
pub fn run(client: *Client) void {
    const io = client.io;
    const opened = openFirst(client) catch |err| {
        connectFailed(client, err);
        return;
    };
    client.connection = opened.connection;
    client.connection_tasks.concurrent(io, readLoop, .{client}) catch |err| return abandon(client, opened, err);
    client.connection_tasks.concurrent(io, writeLoop, .{client}) catch |err| return abandon(client, opened, err);
    log.debug("connected to {f}", .{opened.server});
    connected(client, opened.server, opened.greeting.info_json);
    teardown(client, opened.server, heartbeat(client));
}

/// A connection that passed the handshake.
const Opened = struct {
    connection: Connection,
    greeting: Connection.Greeting,
    server: ServerAddress,
    gpa: Allocator,

    fn release(io: Io, opened: Opened) void {
        opened.connection.stream.close(io);
        opened.gpa.free(opened.greeting.info_json);
    }
};

/// Tries the servers in order, one attempt each; the first that takes the
/// connection wins.
fn openFirst(client: *Client) Client.ConnectError!Opened {
    const io = client.io;
    var last_error: Client.ConnectError = error.ConnectionClosed;
    for (client.options.servers) |*server| {
        log.debug("connecting to {f}", .{server.*});
        const deadline = time.after(io, client.options.options.connect_timeout);
        var state: AttemptState = .{};
        const abort: dialer.Abort = .{ .context = &state, .function = AttemptState.abort };
        if (dialer.race(io, deadline, attempt, .{ client, server, &state }, Opened.release, abort)) |opened| {
            return opened;
        } else |err| switch (err) {
            // close() stops the attempts, and a server that refuses the
            // credentials ends them.
            error.Canceled, error.ConcurrencyUnavailable, error.AuthenticationFailed => return err,
            else => {
                log.debug("could not connect to {f}: {t}", .{ server.*, err });
                last_error = err;
            },
        }
    }
    return last_error;
}

/// The socket of an attempt in progress, for the manager to shut down when
/// time runs out: the attempt may have lost its cancellation and would wait
/// on the socket for good. The mutex keeps shutdown off a closed socket.
const AttemptState = struct {
    mutex: Io.Mutex = .init,
    stream: ?Io.net.Stream = null,
    aborted: bool = false,

    fn abort(context: *anyopaque, io: Io) void {
        const state: *AttemptState = @ptrCast(@alignCast(context));
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        state.aborted = true;
        if (state.stream) |stream| shutdown(io, stream);
    }

    /// Registers the attempt's stream; false when the attempt was aborted
    /// already.
    fn hold(state: *AttemptState, io: Io, stream: Io.net.Stream) bool {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.aborted) return false;
        state.stream = stream;
        return true;
    }

    /// From here on the attempt's stream is no longer the manager's to touch.
    fn release(state: *AttemptState, io: Io) void {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        state.stream = null;
    }
};

/// DNS, TCP and the handshake with one server.
fn attempt(client: *Client, server: *const ServerAddress, state: *AttemptState) (dialer.DialError || Connection.HandshakeError)!Opened {
    const io = client.io;
    const stream = try dialer.dial(io, server);
    if (!state.hold(io, stream)) {
        stream.close(io);
        return error.Timeout;
    }
    var connection: Connection = .init(stream, io, client.read_buffer, client.parser_limits);
    const greeting = connection.handshake(io, client.gpa, .init(&client.options.options)) catch |err| {
        state.release(io);
        stream.close(io);
        return err;
    };
    state.release(io);
    return .{ .connection = connection, .greeting = greeting, .server = server.*, .gpa = client.gpa };
}

/// Shuts `stream` down both ways: a read blocked on it returns the end of
/// the stream and a blocked write fails, whether or not their tasks still
/// see cancellation. The socket stays open for its owner to close.
fn shutdown(io: Io, stream: Io.net.Stream) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    stream.shutdown(io, .both) catch {};
}

/// The reader or writer could not start: the connection is dropped.
fn abandon(client: *Client, opened: Opened, err: Io.ConcurrentError) void {
    const io = client.io;
    shutdown(io, client.connection.stream);
    client.connection_tasks.cancel(io);
    client.connection.stream.close(io);
    client.gpa.free(opened.greeting.info_json);
    connectFailed(client, err);
}

/// Sends a PING every `ping_interval` until the connection must end. After
/// `max_outstanding_pings` PINGs without a PONG the connection is dead.
fn heartbeat(client: *Client) Exit {
    const io = client.io;
    const options = &client.options.options;
    while (true) {
        if (awaitExit(client, time.after(io, options.ping_interval))) |exit| return exit;
        if (client.outbound.pingsOut(io) >= options.max_outstanding_pings) return .stale;
        _ = client.outbound.putPing(io, .heartbeat) catch |err| switch (err) {
            error.Closed => return .closed,
            error.OutOfMemory => log.warn("no memory for a heartbeat PING", .{}),
        };
    }
}

/// Takes the connection down: the queues close and wake their waiters, the
/// socket is shut down so that no read or write blocks any more, the reader
/// and writer are canceled and awaited, and only then does the socket
/// close. Nothing here can be canceled.
fn teardown(client: *Client, server: ServerAddress, exit: Exit) void {
    const io = client.io;
    switch (exit) {
        .closed => log.debug("connection to {f} closed", .{server}),
        .end_of_stream => log.debug("{f} closed the connection", .{server}),
        .stale => log.debug("{f} did not answer PING: connection dropped", .{server}),
        .server_error => |kind| log.debug("{f} ends the connection after {t}", .{ server, kind }),
        .protocol => log.warn("{f} broke the protocol: connection dropped", .{server}),
        .read => |err| log.debug("reading from {f} failed: {t}", .{ server, err }),
        .write => |err| log.debug("writing to {f} failed: {t}", .{ server, err }),
    }
    client.outbound.close(io);
    shutdown(io, client.connection.stream);
    client.connection_tasks.cancel(io);
    client.connection.stream.close(io);
    disconnected(client);
}

/// The reader task of a connection: frames from the server.
fn readLoop(client: *Client) void {
    const io = client.io;
    while (true) {
        const frame = client.connection.next() catch |err| {
            switch (err) {
                error.Canceled => {},
                error.EndOfStream => lose(client, .end_of_stream),
                error.LineTooLong, error.UnknownOperation, error.InvalidArguments, error.MissingTerminator => lose(client, .protocol),
                else => |e| lose(client, .{ .read = e }),
            }
            return;
        };
        switch (frame) {
            .ping => client.outbound.queuePong(io),
            .pong => client.outbound.pongReceived(io),
            .ok => {},
            .info => |json| updateInfo(client, json) catch |err| switch (err) {
                error.InvalidInfo => {
                    lose(client, .protocol);
                    return;
                },
                error.OutOfMemory => log.warn("no memory to keep the server's INFO", .{}),
            },
            .err => |text| {
                log.warn("server error: {s}", .{text});
                const kind = server_error.classify(text).kind;
                if (kind.closesConnection()) {
                    lose(client, .{ .server_error = kind });
                    return;
                }
            },
            // Without subscriptions there is no one to deliver a message to.
            .msg, .body, .msg_end => {},
        }
    }
}

/// The writer task of a connection: batches from the outbound queue.
fn writeLoop(client: *Client) void {
    const io = client.io;
    var slices: [16][]const u8 = undefined;
    while (true) {
        const batch = (client.outbound.take(io, &slices) catch return) orelse return;
        var sent: usize = 0;
        client.connection.writeAll(io, batch.slices, &sent) catch |err| {
            client.outbound.written(io, sent);
            if (err != error.Canceled) lose(client, .{ .write = err });
            return;
        };
        client.outbound.written(io, batch.len);
    }
}

/// The first connection failed, or the manager could not start: the
/// client closes.
pub fn connectFailed(client: *Client, err: Client.ConnectError) void {
    const io = client.io;
    client.mutex.lockUncancelable(io);
    if (client.status == .connecting) client.connect_error = err;
    client.status = .closed;
    client.changed.broadcast(io);
    client.mutex.unlock(io);
    client.outbound.close(io);
}

/// The connection is up; `info_json` is its INFO, now the client's.
fn connected(client: *Client, server: ServerAddress, info_json: []u8) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.status == .connecting) client.status = .connected;
    client.server = server;
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = info_json;
    client.changed.broadcast(client.io);
}

/// The connection is gone, and with it the client.
fn disconnected(client: *Client) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.status = .closed;
    client.server = null;
    if (client.info_json) |json| client.gpa.free(json);
    client.info_json = null;
    client.changed.broadcast(client.io);
}

/// Asks the manager to end the connection; the first reason given stays.
fn lose(client: *Client, exit: Exit) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.exit == null) client.exit = exit;
    client.changed.broadcast(client.io);
}

/// Waits until the connection must end, or until `deadline`: null then.
fn awaitExit(client: *Client, deadline: Io.Clock.Timestamp) ?Exit {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    while (true) {
        if (client.exit) |exit| return exit;
        client.changed.waitTimeout(client.io, &client.mutex, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return null,
            // Only close() and deinit() cancel the manager.
            error.Canceled => return .closed,
        };
    }
}

/// Keeps the server's latest INFO.
fn updateInfo(client: *Client, json: []const u8) error{ InvalidInfo, OutOfMemory }!void {
    const info = try ServerInfo.parse(client.gpa, json);
    info.deinit();
    const copy = try client.gpa.dupe(u8, json);
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = copy;
}
