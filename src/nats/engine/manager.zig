//! The client's tasks. The manager opens the connection, starts its reader
//! and writer and sends heartbeat PINGs. When the connection must end, it
//! takes it down in order: the queues stop and wake their waiters, the
//! socket is shut down, the reader and writer are canceled and awaited, and
//! only then does the socket close. Then it connects again, as the
//! reconnect options say, going round the pool of servers, and a new
//! connection first subscribes to everything the old one had; or the client
//! closes.
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
const Message = @import("../Message.zig");
const Parser = @import("../protocol/Parser.zig");
const server_error = @import("../protocol/server_error.zig");
const Connection = @import("Connection.zig");
const Registry = @import("Registry.zig");
const Pool = @import("Pool.zig");
const Inbox = @import("Inbox.zig");
const backoff = @import("backoff.zig");
const incoming = @import("incoming.zig");
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
    /// The server is about to go away, and another one is in the pool.
    lame_duck,
};

/// The manager task: from `connect()` until the client closes.
pub fn run(client: *Client) void {
    var next: ?Opened = if (client.options.options.retry_initial_connect)
        reconnect(client)
    else
        openFirst(client) catch |err| {
            connectFailed(client, err);
            return;
        };
    while (next) |opened| {
        const server = opened.server;
        const exit = serve(client, opened) orelse return;
        next = if (teardown(client, server, exit)) reconnect(client) else null;
    }
}

/// Makes `opened` the client's connection and keeps it until it must end;
/// null when its reader or writer could not start, and the client closed.
fn serve(client: *Client, opened: Opened) ?Exit {
    const io = client.io;
    client.connection = opened.connection;
    // Before the reader starts: an INFO it reads is newer than this one.
    adopt(client, opened.server, opened.greeting);
    client.connection_tasks.concurrent(io, readLoop, .{client}) catch |err| {
        abandon(client, err);
        return null;
    };
    client.connection_tasks.concurrent(io, writeLoop, .{client}) catch |err| {
        abandon(client, err);
        return null;
    };
    log.debug("connected to {f}", .{opened.server});
    connected(client);
    return heartbeat(client);
}

/// Connects again after the connection was lost, or for the first time
/// with `retry_initial_connect`: the first attempt at once, then after
/// growing waits, going round the pool. Null when the client closed, or
/// gave up after `max_attempts` failures in a row and closed.
fn reconnect(client: *Client) ?Opened {
    const io = client.io;
    const options = &client.options.options;
    if (!beginReconnecting(client)) return null;
    var failures: u32 = 0;
    while (true) {
        if (failures > 0) {
            const wait = backoff.delay(options.reconnect, failures, randomNumber(io));
            if (awaitExit(client, time.after(io, wait)) != null) return null;
        }
        const server = client.pool.next(io);
        var state: AttemptState = .{};
        if (!track(client, &state)) return null;
        defer untrack(client);
        log.debug("reconnecting to {f}", .{server});
        const deadline = time.after(io, options.connect_timeout);
        const abort: dialer.Abort = .{ .context = &state, .function = AttemptState.abort };
        if (dialer.race(io, deadline, attempt, .{ client, &server, &state }, Opened.release, abort)) |opened| {
            _ = client.pool.noteAttempt(io, null);
            if (restored(client, opened)) return opened;
        } else |err| switch (err) {
            // close() stops the attempts.
            error.Canceled => return null,
            error.ConcurrencyUnavailable => {
                giveUp(client, .reconnect_failed);
                return null;
            },
            // A server that refuses the credentials twice the same way in
            // a row does not change its mind: the client stops.
            error.AuthenticationFailed => {
                log.debug("{f} refused the credentials", .{server});
                if (client.pool.noteAttempt(io, state.refused) and options.reconnect.abort_on_auth_error) {
                    log.debug("{f} refused the credentials twice: closing", .{server});
                    giveUp(client, .auth_failed);
                    return null;
                }
            },
            else => {
                log.debug("could not reconnect to {f}: {t}", .{ server, err });
                _ = client.pool.noteAttempt(io, null);
            },
        }
        failures +|= 1;
        if (options.reconnect.max_attempts) |max| {
            if (failures >= max) {
                log.debug("no connection after {d} attempts: closing", .{failures});
                giveUp(client, .reconnect_failed);
                return null;
            }
        }
    }
}

/// The new connection first subscribes to everything the subscriptions
/// and the inbox had, before any frame that waits; false, and the
/// connection is dropped, when there is no memory for that or the client
/// closed.
fn restored(client: *Client, opened: Opened) bool {
    client.outbound.restore(client.io, client, restoreFrames) catch |err| {
        if (err == error.OutOfMemory) log.warn("no memory to subscribe again on {f}: connection dropped", .{opened.server});
        Opened.release(client.io, opened);
        return false;
    };
    return true;
}

/// SUB of every subscription that still takes messages and of the inbox,
/// with the SIDs they had, and `UNSUB sid n` for those that end after a
/// number of messages. It runs under the outbound queue's mutex.
fn restoreFrames(client: *Client, gpa: Allocator) Allocator.Error![]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    var subject: [Inbox.prefix_len + 1]u8 = undefined;
    const inbox: ?Registry.Resubscribe = if (client.inbox.restoreSub(client.io, &subject)) |sid| .{ .subject = &subject, .sid = sid } else null;
    client.subscriptions.writeRestore(client.io, &w.writer, inbox) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

fn randomNumber(io: Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
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

/// Tries the servers of the pool in its order, one attempt each; the first
/// that takes the connection wins.
fn openFirst(client: *Client) Client.ConnectError!Opened {
    const io = client.io;
    var last_error: Client.ConnectError = error.ConnectionClosed;
    for (0..client.pool.count(io)) |_| {
        const server = client.pool.next(io);
        var state: AttemptState = .{};
        if (!track(client, &state)) return error.Canceled;
        defer untrack(client);
        log.debug("connecting to {f}", .{server});
        const deadline = time.after(io, client.options.options.connect_timeout);
        const abort: dialer.Abort = .{ .context = &state, .function = AttemptState.abort };
        if (dialer.race(io, deadline, attempt, .{ client, &server, &state }, Opened.release, abort)) |opened| {
            _ = client.pool.noteAttempt(io, null);
            if (restored(client, opened)) return opened;
            last_error = error.OutOfMemory;
        } else |err| switch (err) {
            // close() stops the attempts, and a server that refuses the
            // credentials ends them.
            error.Canceled, error.ConcurrencyUnavailable, error.AuthenticationFailed => return err,
            else => {
                log.debug("could not connect to {f}: {t}", .{ server, err });
                last_error = err;
            },
        }
    }
    return last_error;
}

/// The socket of an attempt in progress, for the manager or `close()` to
/// shut down: the attempt may have lost its cancellation and would wait on
/// the socket for good. The mutex keeps shutdown off a closed socket.
pub const AttemptState = struct {
    mutex: Io.Mutex = .init,
    stream: ?Io.net.Stream = null,
    aborted: bool = false,
    /// How the server refused the credentials, when it did.
    refused: ?server_error.Refusal = null,

    /// Makes the attempt end soon: now, or as soon as it has a socket.
    pub fn stop(state: *AttemptState, io: Io) void {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        state.aborted = true;
        if (state.stream) |stream| shutdown(io, stream);
    }

    fn abort(context: *anyopaque, io: Io) void {
        const state: *AttemptState = @ptrCast(@alignCast(context));
        state.stop(io);
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
        state.refused = connection.refused;
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

/// The reader or writer could not start: the connection is dropped, and
/// the client closes.
fn abandon(client: *Client, err: Io.ConcurrentError) void {
    const io = client.io;
    shutdown(io, client.connection.stream);
    client.connection_tasks.cancel(io);
    client.connection.stream.close(io);
    connectFailed(client, err);
    client.inbox.end(io, .closed);
    disconnected(client);
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
            // The connection is being taken down: the exit comes next.
            error.Disconnected => {},
            error.OutOfMemory => log.warn("no memory for a heartbeat PING", .{}),
        };
    }
}

/// Takes the connection down: the queues stop and wake their waiters, the
/// socket is shut down so that no read or write blocks any more, the reader
/// and writer are canceled and awaited, and only then does the socket
/// close. True when the client goes on to reconnect; otherwise it is
/// closed. Nothing here can be canceled.
fn teardown(client: *Client, server: ServerAddress, exit: Exit) bool {
    const io = client.io;
    switch (exit) {
        .closed => log.debug("connection to {f} closed", .{server}),
        .end_of_stream => log.debug("{f} closed the connection", .{server}),
        .stale => log.debug("{f} did not answer PING: connection dropped", .{server}),
        .server_error => |kind| log.debug("{f} ends the connection after {t}", .{ server, kind }),
        .protocol => log.warn("{f} broke the protocol: connection dropped", .{server}),
        .read => |err| log.debug("reading from {f} failed: {t}", .{ server, err }),
        .write => |err| log.debug("writing to {f} failed: {t}", .{ server, err }),
        .lame_duck => log.debug("{f} goes away: moving to another server", .{server}),
    }
    const again = lost(client, exit);
    // Before the outbound queue wakes them, requests learn why.
    if (again) {
        client.inbox.disconnect(io);
        client.outbound.halt(io);
    } else {
        client.inbox.end(io, if (exit == .closed) .closed else .disconnected);
        client.outbound.close(io);
    }
    shutdown(io, client.connection.stream);
    client.connection_tasks.cancel(io);
    client.connection.stream.close(io);
    if (!again) {
        disconnected(client);
        _ = client.outbound.discard(io);
        return false;
    }
    // Nothing the connection left is sent again: publishes it never wrote
    // wait in the reconnect buffer.
    _ = client.outbound.settle(io);
    return true;
}

/// The connection is gone: true when the client reconnects, and it is
/// reconnecting from now on. Not after `close()`, during drain, or with
/// reconnect off.
fn lost(client: *Client, exit: Exit) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.server = null;
    if (client.info_json) |json| client.gpa.free(json);
    client.info_json = null;
    const again = exit != .closed and client.status == .connected and client.options.options.reconnect.enabled;
    if (again) {
        client.status = .reconnecting;
    } else {
        // Closed before the queues wake their waiters: a drain learns why.
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = .connection_lost;
    }
    client.changed.broadcast(client.io);
    return again;
}

/// Reconnecting starts: false when the client closed meanwhile.
fn beginReconnecting(client: *Client) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.status == .closed) return false;
    client.exit = null;
    return true;
}

/// The client gives up reconnecting and closes: every task waiting in it
/// gets ConnectionClosed.
fn giveUp(client: *Client, reason: Client.CloseReason) void {
    const io = client.io;
    {
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = reason;
        if (client.exit == null) client.exit = .closed;
        client.changed.broadcast(io);
    }
    client.inbox.end(io, .closed);
    client.outbound.close(io);
    client.subscriptions.closeAll(io);
    _ = client.outbound.discard(io);
}

/// The reader task of a connection: frames from the server.
fn readLoop(client: *Client) void {
    const io = client.io;
    // The message being read; freed if the reader stops half way.
    var current: ?Incoming = null;
    defer if (current) |*c| c.abandon();
    while (true) {
        const frame = client.connection.next() catch |err| {
            if (readExit(err)) |exit| lose(client, exit);
            return;
        };
        switch (frame) {
            .ping => client.outbound.queuePong(io),
            .pong => client.outbound.pongReceived(io),
            .ok => {},
            .info => |json| updateInfo(client, json) catch |err| switch (err) {
                error.ProtocolError => {
                    lose(client, .protocol);
                    return;
                },
                error.OutOfMemory => log.warn("no memory to keep the server's INFO", .{}),
            },
            .err => |text| {
                log.warn("server error: {s}", .{text});
                const classified = server_error.classify(text);
                // It counts as the server's first refusal for reconnecting.
                if (classified.kind == .authentication_failed) _ = client.pool.noteAttempt(io, server_error.refusal(text));
                if (classified.kind.closesConnection()) {
                    lose(client, .{ .server_error = classified.kind });
                    return;
                }
                // A refused publish only costs that message; a refused
                // subscription ends, and a refused inbox fails the requests.
                if (classified.permission) |permission| {
                    if (permission.operation == .subscribe) {
                        if (client.inbox.deny(io, permission)) {
                            log.debug("the inbox subscription was refused: requests fail with PermissionDenied", .{});
                        } else if (client.subscriptions.deny(io, permission)) |sid| {
                            log.debug("subscription {d} refused", .{sid});
                        }
                    }
                }
            },
            .msg => |msg| {
                // The parser ends every message before the next; even so,
                // nothing half read may leak.
                if (current) |*c| c.abandon();
                current = .begin(client, msg);
            },
            .body => |bytes| if (current) |*c| c.append(bytes),
            .msg_end => if (current) |*c| {
                c.finish(client);
                current = null;
            },
        }
    }
}

/// Why a failed read ends the connection; null when the reader was
/// canceled. A read after this client shut the socket down fails too: on
/// Windows with Unexpected, which std prints in Debug builds (it does not
/// map the status PIPE_DISCONNECTED). That is the end of the connection,
/// logged at debug like any read error, and the reason given first stays.
fn readExit(err: Connection.ReadError) ?Exit {
    return switch (err) {
        error.Canceled => null,
        error.EndOfStream => .end_of_stream,
        error.LineTooLong, error.UnknownOperation, error.InvalidArguments, error.MissingTerminator => .protocol,
        else => |e| .{ .read = e },
    };
}

/// A message the reader is in the middle of. It is kept only when a
/// subscription or a waiting request takes it and it is within the limits;
/// otherwise its bytes are read past without an allocation.
const Incoming = struct {
    sid: u64,
    /// Bytes of the header block and payload, as announced.
    total_len: u32,
    assembly: ?incoming.Assembly,
    skipped: Skipped,
    /// The request a reply on the inbox names; null for a subscription's
    /// message.
    request: ?u64,

    const Skipped = enum {
        /// Kept.
        no,
        /// No subscription takes it, or it came to the inbox under a
        /// subject that names no request: dropped without a word.
        unrouted,
        /// A reply no request waits for: counted as late.
        late,
        /// Over `max_inbound_frame_bytes` or `max_header_bytes`, or more
        /// than its subscription holds even when empty.
        too_large,
        no_memory,
    };

    fn begin(client: *Client, msg: Parser.Msg) Incoming {
        var in: Incoming = .{ .sid = msg.sid, .total_len = msg.total_len, .assembly = null, .skipped = .no, .request = null };
        const limits = &client.options.options.limits;
        const holds = if (client.inbox.owns(msg.sid)) reply: {
            const id = client.inbox.requestId(msg.subject) orelse {
                in.skipped = .unrouted;
                return in;
            };
            in.request = id;
            break :reply client.inbox.accepts(client.io, id) orelse {
                in.skipped = .late;
                return in;
            };
        } else client.subscriptions.accepts(client.io, msg.sid) orelse {
            in.skipped = .unrouted;
            return in;
        };
        if (msg.total_len > limits.max_inbound_frame_bytes or msg.header_len > limits.max_header_bytes or
            incoming.Assembly.size(msg) > holds)
        {
            in.skipped = .too_large;
        } else if (incoming.Assembly.begin(client.gpa, msg)) |assembly| {
            in.assembly = assembly;
        } else |_| {
            in.skipped = .no_memory;
        }
        return in;
    }

    fn append(in: *Incoming, bytes: []const u8) void {
        if (in.assembly) |*assembly| assembly.append(bytes);
    }

    /// The message is complete: to its subscription, which counts it even
    /// when it could not be kept.
    fn finish(in: *Incoming, client: *Client) void {
        if (in.skipped == .unrouted) return;
        if (in.request) |id| return in.finishReply(client, id);
        const message: ?Message = if (in.assembly) |*assembly| assembly.finish() else null;
        const pushed = client.subscriptions.deliver(client.io, in.sid, message) orelse return;
        switch (in.skipped) {
            .no, .unrouted, .late => {},
            .too_large => log.warn("a message of {d} bytes for subscription {d} is over the limits: dropped", .{ in.total_len, in.sid }),
            .no_memory => log.warn("no memory for a message of {d} bytes for subscription {d}: dropped", .{ in.total_len, in.sid }),
        }
        if (pushed.no_memory) log.warn("no memory to queue a message for subscription {d}: dropped", .{in.sid});
        if (pushed.ended == .slow_consumer) {
            log.warn("subscription {d} is a slow consumer: closed", .{in.sid});
            // The reader cannot wait for room: the UNSUB goes in at once.
            Registry.queueUnsub(&client.outbound, client.io, in.sid) catch |err| {
                log.debug("no UNSUB for subscription {d}: {t}", .{ in.sid, err });
            };
        } else if (pushed.overflow_began) {
            log.warn("subscription {d} is a slow consumer: messages dropped", .{in.sid});
        }
    }

    /// The reply to request `id` is complete: to the request, or late.
    fn finishReply(in: *Incoming, client: *Client, id: u64) void {
        if (in.skipped == .late) return client.inbox.noteLate(client.io);
        const message: ?Message = if (in.assembly) |*assembly| assembly.finish() else null;
        _ = client.inbox.deliver(client.io, id, message);
        switch (in.skipped) {
            .no, .unrouted, .late => {},
            .too_large => log.warn("a reply of {d} bytes is over the limits: dropped", .{in.total_len}),
            .no_memory => log.warn("no memory for a reply of {d} bytes: dropped", .{in.total_len}),
        }
    }

    fn abandon(in: *Incoming) void {
        if (in.assembly) |*assembly| assembly.discard();
    }
};

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
    if (client.close_reason == null) client.close_reason = .connect_failed;
    client.changed.broadcast(io);
    client.mutex.unlock(io);
    client.outbound.close(io);
}

/// The connection passed its handshake with `server`; the INFO of
/// `greeting` is now the client's, and the servers it announces join the
/// pool.
fn adopt(client: *Client, server: ServerAddress, greeting: Connection.Greeting) void {
    if (ServerInfo.parse(client.gpa, greeting.info_json)) |info| {
        defer info.deinit();
        discover(client, info.value);
        if (info.value.ldm) lameDuck(client);
    } else |err| log.debug("the INFO of the handshake is unreadable now: {t}", .{err});
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.server = server;
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = greeting.info_json;
    client.server_headers = greeting.headers;
    client.max_payload = maxPayload(greeting.max_payload);
}

/// The server is about to go away: the client moves to another one at once
/// when the pool has one and reconnecting is on; otherwise it stays until
/// the server closes the connection.
fn lameDuck(client: *Client) void {
    log.debug("the server is entering lame duck mode", .{});
    if (!client.options.options.reconnect.enabled or client.pool.count(client.io) < 2) return;
    // A drain finishes on this server.
    if (client.state() != .connected) return;
    lose(client, .lame_duck);
}

/// The servers an INFO announces join the pool, and the discovered ones it
/// no longer names leave it.
fn discover(client: *Client, info: ServerInfo) void {
    if (client.options.options.ignore_discovered_servers) return;
    client.pool.update(client.io, info.connect_urls, &Pool.ignore_changes);
}

/// The `max_payload` of an INFO; 0 when the server gave none, or one that
/// cannot be a size.
fn maxPayload(announced: i64) u64 {
    return if (announced > 0) @intCast(announced) else 0;
}

/// The connection is up, its reader and writer run.
fn connected(client: *Client) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.status == .connecting or client.status == .reconnecting) client.status = .connected;
    client.changed.broadcast(client.io);
}

/// The connection is gone, and with it the client and its subscriptions.
fn disconnected(client: *Client) void {
    {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = .connection_lost;
        client.server = null;
        if (client.info_json) |json| client.gpa.free(json);
        client.info_json = null;
        client.changed.broadcast(client.io);
    }
    client.subscriptions.closeAll(client.io);
}

/// Lets `close()` stop the attempt; false when the client is closing.
fn track(client: *Client, state: *AttemptState) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.exit != null) return false;
    client.attempt = state;
    return true;
}

fn untrack(client: *Client) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.attempt = null;
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

/// Keeps the server's latest INFO. Its `max_payload` applies from now on,
/// such as the limit of the user's account in the INFO after CONNECT.
/// Headers stay as CONNECT settled them.
fn updateInfo(client: *Client, json: []const u8) ServerInfo.ParseError!void {
    const info = try ServerInfo.parse(client.gpa, json);
    defer info.deinit();
    discover(client, info.value);
    if (info.value.ldm) lameDuck(client);
    const copy = try client.gpa.dupe(u8, json);
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = copy;
    client.max_payload = maxPayload(info.value.max_payload);
}

const testing = std.testing;

test "a failed read ends the connection as a read error, not as broken protocol" {
    // Windows reports a read after our own shutdown so.
    try testing.expectEqual(Exit{ .read = error.Unexpected }, readExit(error.Unexpected).?);
    try testing.expectEqual(Exit{ .read = error.ConnectionResetByPeer }, readExit(error.ConnectionResetByPeer).?);
    try testing.expectEqual(Exit.end_of_stream, readExit(error.EndOfStream).?);
    try testing.expectEqual(Exit.protocol, readExit(error.MissingTerminator).?);
    try testing.expect(readExit(error.Canceled) == null);
}
