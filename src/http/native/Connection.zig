//! One connection of `http.native.Backend`, on a task of its own: it reads
//! the heads of requests one after another, hands each to the server as an
//! `http.Backend.Exchange` and sends its response, until the connection
//! closes.
//!
//! - **The first byte.** A new connection sends its first byte within
//!   `timeouts.header`, a kept one its next request within `timeouts.idle`;
//!   else it closes without an answer. This wait races the backend's stop
//!   event in an `Io.Select`, so a stop closes it at once.
//! - **The head.** From its first byte, the whole head comes within
//!   `timeouts.header`, one deadline for all its reads; else 408. A head the
//!   parser refuses gets its status (400, 414, 417, 431, 501, 505). Either
//!   answer is short text with `Connection: close`.
//! - **The response.** The backend writes `Date`, the length or chunked
//!   (to the end of the connection for HTTP/1.0), and `Connection`. HEAD,
//!   204 and 304 go without a body. Each write sends something within
//!   `timeouts.write`, else the connection closes.
//! - **Keep-alive and pipelining.** Requests run one after another; bytes
//!   that follow a head stay in the buffer for the next one. The arena of
//!   the requests keeps at most 64 KiB between them.
//! - **The watcher.** Once a request's body has been read, the server's
//!   guard calls `watch`: it reads ahead into the buffer, so a client that
//!   leaves (or half-closes) is seen at once, and the bytes it reads stay
//!   for the next request.
//!
//! A response that closes the connection ends with a lingering close: the
//! backend ends its side, then reads and drops what the client still sends
//! for a moment, so the client reads the response before the connection
//! resets.
const std = @import("std");
const core = @import("core");
const Interface = @import("../Backend.zig");
const Exchange = Interface.Exchange;
const Backend = @import("Backend.zig");
const socket = @import("socket.zig");
const h1 = @import("../h1/head.zig");
const response = @import("../h1/response.zig");
const date = @import("../h1/date.zig");

const Connection = @This();
const Duration = std.Io.Duration;
const net = std.Io.net;
const log = std.log.scoped(.http);

backend: *Backend,
stream: net.Stream,
/// Bytes read and not yet used: the rest of a head, what follows it, what
/// the watcher reads ahead. `max_head_bytes` long.
buffer: []u8,
len: usize = 0,
/// The fields of the head being read; `max_header_fields` long.
fields: []h1.Field,
/// The memory of a request: its head, the server's arena, the head of its
/// response. Reset after each request.
arena: std.heap.ArenaAllocator,
/// The request being served.
request: Request = undefined,
out: Out = .{},
exchange: Exchange = undefined,

/// What the arena keeps between two requests.
const arena_retain = 64 << 10;
/// How long a lingering close reads what the client still sends, and how
/// much of it.
const linger_time: Duration = .fromSeconds(1);
const linger_bytes = 64 << 10;

/// The head of the request being served, as the connection needs it.
const Request = struct {
    method: std.http.Method,
    version: h1.Version,
    framing: h1.Framing,
    /// The client keeps the connection: HTTP/1.1 without `Connection:
    /// close`, HTTP/1.0 with `Connection: keep-alive`.
    keep_alive: bool,
};

/// The response being written.
const Out = struct {
    state: enum { ready, head, body, finished, broken } = .ready,
    /// The head, not sent yet: it goes out with the first bytes of the body,
    /// or at `flush` or `finish`.
    pending: []const u8 = "",
    framing: response.Framing = .none,
    /// The body goes on the wire: not for HEAD, 204 and 304.
    send_body: bool = false,
    /// Bytes of the body written, sent or not.
    written: u64 = 0,
    /// The connection closes after this response.
    close: bool = false,
};

/// Serves a connection the backend has accepted, until it closes; on a task
/// of the backend's connections. The socket closes only here, after every
/// task that reads or writes it has ended.
pub fn serve(b: *Backend, io: std.Io, stream: net.Stream) void {
    // The slot of the connection is free once its socket has closed.
    defer b.slots.post(io);
    defer stream.close(io);
    const buffer = b.gpa.alloc(u8, b.limits.max_head_bytes) catch return outOfMemory();
    defer b.gpa.free(buffer);
    const fields = b.gpa.alloc(h1.Field, b.limits.max_header_fields) catch return outOfMemory();
    defer b.gpa.free(fields);
    var conn: Connection = .{ .backend = b, .stream = stream, .buffer = buffer, .fields = fields, .arena = .init(b.gpa) };
    defer conn.arena.deinit();
    conn.run(io);
}

fn outOfMemory() void {
    log.warn("out of memory for a new connection; it is closed", .{});
}

/// How a request left the connection.
const End = enum {
    /// The next request may follow.
    keep_alive,
    /// A response went out that closes the connection: a lingering close.
    close,
    /// Close now: nothing to answer, or the client has gone.
    drop,
};

fn run(conn: *Connection, io: std.Io) void {
    const t = conn.backend.timeouts;
    var first = true;
    while (true) {
        if (conn.len == 0 and !conn.awaitBytes(io, if (first) t.header else t.idle)) return;
        first = false;
        switch (conn.serveOne(io)) {
            .keep_alive => _ = conn.arena.reset(.{ .retain_with_limit = arena_retain }),
            .close => return conn.lingerClose(io),
            .drop => return,
        }
    }
}

/// What ended the wait for the first bytes of a request.
const Wake = union(enum) {
    read: socket.ReadError!usize,
    stop: std.Io.Cancelable!void,
};

/// Waits for the first bytes of a request, `limit` at most, racing the
/// backend's stop. False: the connection closes now (no bytes in time, the
/// end of the stream, a broken connection, the stop, or a cancelation).
fn awaitBytes(conn: *Connection, io: std.Io, limit: Duration) bool {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), limit);
    var results: [2]Wake = undefined;
    var select: std.Io.Select(Wake) = .init(io, &results);
    select.concurrent(.read, socket.read, .{ io, conn.stream, conn.buffer, deadline }) catch
        return noTask();
    select.concurrent(.stop, std.Io.Event.wait, .{ &conn.backend.stop_event, io }) catch {
        select.cancelDiscard();
        return noTask();
    };
    // Canceled: the stop's grace is over.
    const first = select.await() catch {
        select.cancelDiscard();
        return false;
    };
    select.cancelDiscard();
    switch (first) {
        .read => |result| {
            const n = result catch return false;
            conn.len = n;
            return n > 0;
        },
        .stop => return false,
    }
}

fn noTask() bool {
    log.warn("the runtime gave no task for the wait of a connection; it is closed", .{});
    return false;
}

/// Reads the head of the next request from what the buffer holds and the
/// socket, serves it and tells what follows.
fn serveOne(conn: *Connection, io: std.Io) End {
    const b = conn.backend;
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), b.timeouts.header);
    const h = switch (conn.readHead(io, deadline)) {
        .head => |h| h,
        .refused => |status| return conn.refuse(io, status),
        .gone => return .drop,
    };
    const target = conn.keepHead(h) catch {
        log.warn("out of memory for the head of a request; the connection is closed", .{});
        return .drop;
    };
    conn.request = .{ .method = h.method, .version = h.version, .framing = h.framing, .keep_alive = h.keep_alive };
    conn.out = .{};
    conn.exchange = .{
        .ptr = conn,
        .vtable = &exchange_vtable,
        .method = h.method,
        .target = target,
        .version = h.version,
        .fields = conn.fields[0..h.fields.len],
        .client = conn.stream.socket.address,
        .arena = conn.arena.allocator(),
    };
    b.handler.serve(b.handler.ptr, io, &conn.exchange);
    return switch (conn.out.state) {
        .finished => if (conn.out.close) .close else .keep_alive,
        // Aborted, broken, or never written.
        .ready, .head, .body, .broken => .drop,
    };
}

const HeadRead = union(enum) {
    head: h1.Head,
    /// The status to answer before closing: the parser's, or 408.
    refused: u16,
    /// The end of the stream, a broken connection, or a cancelation.
    gone,
};

/// Reads until the buffer holds a whole head, by `deadline`. The parser
/// scans from the start of the buffer, so it runs only when new bytes hold
/// a line feed (a head ends with one) or the buffer is full.
fn readHead(conn: *Connection, io: std.Io, deadline: core.Deadline) HeadRead {
    const l = conn.backend.limits;
    const limits: h1.Limits = .{ .max_head_bytes = l.max_head_bytes, .max_header_fields = l.max_header_fields, .max_target_bytes = l.max_target_bytes };
    var scanned: usize = 0;
    while (true) {
        const full = conn.len == conn.buffer.len;
        if (full or std.mem.findScalar(u8, conn.buffer[scanned..conn.len], '\n') != null) {
            const found = h1.parseHead(conn.buffer[0..conn.len], limits, conn.fields) catch |err|
                return .{ .refused = h1.statusOf(err) };
            if (found) |h| return .{ .head = h };
            // A full buffer always gives a head or an error.
            if (full) return .{ .refused = 431 };
        }
        scanned = conn.len;
        const n = socket.read(io, conn.stream, conn.buffer[conn.len..], deadline) catch |err| return switch (err) {
            error.Timeout => .{ .refused = 408 },
            error.ReadFailed, error.Canceled => .gone,
        };
        if (n == 0) return .gone;
        conn.len += n;
    }
}

/// Moves the head into the arena, so that the buffer holds only what
/// follows it, and points the target and the fields there. Returns the
/// target.
fn keepHead(conn: *Connection, h: h1.Head) error{OutOfMemory}![]const u8 {
    const bytes = try conn.arena.allocator().dupe(u8, conn.buffer[0..h.len]);
    const base = @intFromPtr(conn.buffer.ptr);
    const move = struct {
        fn slice(to: []const u8, from: usize, s: []const u8) []const u8 {
            if (s.len == 0) return "";
            return to[@intFromPtr(s.ptr) - from ..][0..s.len];
        }
    }.slice;
    for (conn.fields[0..h.fields.len]) |*f| f.* = .{ .name = move(bytes, base, f.name), .value = move(bytes, base, f.value) };
    const target = move(bytes, base, h.target);
    conn.consume(h.len);
    return target;
}

fn consume(conn: *Connection, n: usize) void {
    std.mem.copyForwards(u8, conn.buffer[0 .. conn.len - n], conn.buffer[n..conn.len]);
    conn.len -= n;
}

/// The answer of the backend to a head it does not take: the status, its
/// reason as text, `Connection: close`.
fn refuse(conn: *Connection, io: std.Io, status: u16) End {
    const text = response.reason(status);
    conn.request = .{ .method = .GET, .version = .http11, .framing = .none, .keep_alive = false };
    conn.out = .{};
    const fields = [_]h1.Field{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }};
    conn.startResponse(io, status, &fields, .{ .length = text.len }) catch return .drop;
    conn.writeBodyBytes(io, text) catch return .drop;
    conn.finishResponse(io) catch return .drop;
    return .close;
}

/// Ends the connection after a response that closes it: the backend ends
/// its side, so the client reads the response and its end, then reads and
/// drops what the client still sends, `linger_bytes` for `linger_time` at
/// most. Closing at once with bytes unread would reset the connection, and
/// the reset can destroy the response before the client reads it.
fn lingerClose(conn: *Connection, io: std.Io) void {
    conn.stream.shutdown(io, .send) catch return;
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), linger_time);
    var dropped: usize = 0;
    while (dropped < linger_bytes) {
        const n = socket.read(io, conn.stream, conn.buffer, deadline) catch return;
        if (n == 0) return;
        dropped += n;
    }
}

/// The body of a request is still on the wire after the response: the
/// connection cannot read the next request.
fn bodyUnread(conn: *const Connection) bool {
    return switch (conn.request.framing) {
        .none => false,
        .length => |n| n > 0,
        .chunked => true,
    };
}

/// How the response's body goes on the wire: `kind` as the server gives
/// it, for the request's method and version and the status.
fn framingOf(method: std.http.Method, version: h1.Version, status: u16, kind: Exchange.BodyKind) response.Framing {
    if (status < 200 or status == 204 or status == 304) return .none;
    return switch (kind) {
        // Every other status has a body, if an empty one.
        .none => .{ .length = 0 },
        .length => |n| .{ .length = n },
        // A HEAD response has no body to delimit.
        .stream => if (method == .HEAD) .none else switch (version) {
            .http11 => .chunked,
            .http10 => .until_close,
        },
    };
}

fn startResponse(conn: *Connection, io: std.Io, status: u16, fields: []const h1.Field, kind: Exchange.BodyKind) Exchange.WriteError!void {
    const out = &conn.out;
    if (out.state != .ready) return conn.misuse("a second head");
    const framing = framingOf(conn.request.method, conn.request.version, status, kind);
    const close = !conn.request.keep_alive or conn.bodyUnread() or framing == .until_close or
        conn.backend.stopping.load(.acquire);
    var imf_date: [date.len]u8 = undefined;
    _ = date.formatImfFixdate(std.Io.Clock.real.now(io), &imf_date);
    const bytes = conn.arena.allocator().alloc(u8, headBound(status, fields)) catch {
        log.warn("out of memory for the head of a response; the connection is closed", .{});
        out.state = .broken;
        return error.WriteFailed;
    };
    var w: std.Io.Writer = .fixed(bytes);
    response.writeHead(&w, conn.request.version, status, fields, framing, close, &imf_date) catch
        return conn.misuse("a head longer than its bound");
    out.* = .{
        .state = .head,
        .pending = w.buffered(),
        .framing = framing,
        .send_body = conn.request.method != .HEAD and framing != .none,
        .close = close,
    };
}

/// The most bytes `response.writeHead` writes for `status` and `fields`.
fn headBound(status: u16, fields: []const h1.Field) usize {
    var n: usize = "HTTP/1.1 000 \r\n".len + response.reason(status).len;
    for (fields) |f| n += f.name.len + f.value.len + ": \r\n".len;
    n += "Date: \r\n".len + date.len;
    n += "Content-Length: 18446744073709551615\r\n".len; // longer than Transfer-Encoding: chunked
    n += "Connection: keep-alive\r\n".len + "\r\n".len;
    return n;
}

fn writeBodyBytes(conn: *Connection, io: std.Io, data: []const u8) Exchange.WriteError!void {
    const out = &conn.out;
    switch (out.state) {
        .head, .body => out.state = .body,
        .ready => return conn.misuse("a body before its head"),
        .finished, .broken => return conn.misuse("a body after the end of its response"),
    }
    if (out.framing == .length) {
        if (out.written + data.len > out.framing.length) return conn.misuse("a body over its length");
    }
    out.written += data.len;
    if (!out.send_body or data.len == 0) return;
    switch (out.framing) {
        .length, .until_close => try conn.send(io, &.{data}),
        .chunked => {
            var line: [response.max_chunk_header]u8 = undefined;
            try conn.send(io, &.{ response.chunkHeader(&line, data.len), data, response.chunk_end });
        },
        .none => unreachable, // send_body is false
    }
}

fn finishResponse(conn: *Connection, io: std.Io) Exchange.WriteError!void {
    const out = &conn.out;
    switch (out.state) {
        .head, .body => {},
        .ready => return conn.misuse("the end of a response before its head"),
        .finished, .broken => return conn.misuse("a second end of a response"),
    }
    if (out.send_body and out.framing == .length and out.written < out.framing.length) {
        // The client would wait for the rest: the connection closes.
        out.state = .broken;
        return error.WriteFailed;
    }
    const tail: []const []const u8 = if (out.send_body and out.framing == .chunked) &.{response.last_chunk} else &.{};
    try conn.send(io, tail);
    out.state = .finished;
}

/// Sends the pending head, then `data`. A failure breaks the response: the
/// connection closes after it.
fn send(conn: *Connection, io: std.Io, data: []const []const u8) Exchange.WriteError!void {
    const head = conn.out.pending;
    conn.out.pending = "";
    socket.writeAll(io, conn.stream, head, data, conn.backend.timeouts.write) catch |err| {
        conn.out.state = .broken;
        return switch (err) {
            error.Canceled => error.Canceled,
            error.Timeout, error.WriteFailed => error.WriteFailed,
        };
    };
}

/// The server called the exchange out of order: a bug of the server.
fn misuse(conn: *Connection, what: []const u8) Exchange.WriteError {
    log.err("the server misused the exchange of a connection: {s}", .{what});
    conn.out.state = .broken;
    return error.WriteFailed;
}

fn of(ptr: *anyopaque) *Connection {
    return @ptrCast(@alignCast(ptr));
}

const exchange_vtable: Exchange.VTable = .{
    .bodyLength = bodyLength,
    .readBody = readBody,
    .bodyFailure = bodyFailure,
    .watch = watch,
    .writeHead = writeHead,
    .writeBody = writeBody,
    .flush = flush,
    .finish = finish,
    .abort = abort,
};

fn bodyLength(ptr: *anyopaque) ?u64 {
    return switch (of(ptr).request.framing) {
        .none => 0,
        .length => |n| n,
        .chunked => null,
    };
}

/// The body of a request: none so far. A request with a body gets
/// `ReadFailed`, and its connection closes after the response, its body
/// unread.
fn readBody(ptr: *anyopaque, io: std.Io, _: []u8) Exchange.ReadError!usize {
    try io.checkCancel();
    return switch (of(ptr).request.framing) {
        .none => 0,
        .length => |n| if (n == 0) 0 else error.ReadFailed,
        .chunked => error.ReadFailed,
    };
}

fn bodyFailure(_: *anyopaque) ?Exchange.BodyFailure {
    return null;
}

/// Reads ahead into the buffer until the client goes or `deadline` passes:
/// what it reads stays for the next request. With the buffer full it reads
/// no more and waits for the deadline. The server's guard calls it once
/// the body has been read, so nothing else reads the socket meanwhile.
fn watch(ptr: *anyopaque, io: std.Io, deadline: std.Io.Timeout) Exchange.Watch {
    const conn = of(ptr);
    const limit: ?core.Deadline = switch (deadline) {
        .none => null,
        .duration => |d| .after(std.Io.Clock.awake.now(io), d.raw),
        .deadline => |at| .at(at.toClock(io, .awake).raw),
    };
    while (conn.len < conn.buffer.len) {
        const n = socket.read(io, conn.stream, conn.buffer[conn.len..], limit) catch |err| return switch (err) {
            error.Timeout => .deadline,
            error.ReadFailed => .client_gone,
            // The request has ended and the server drops what this returns;
            // were it taken, no response is the safe answer.
            error.Canceled => .client_gone,
        };
        // The end of the stream: the client has gone, or half-closed after
        // its request, which is the same to the server.
        if (n == 0) return .client_gone;
        conn.len += n;
    }
    sleepUntil(io, limit) catch return .client_gone;
    return .deadline;
}

/// Sleeps until the awake clock passes `deadline`; null: until canceled.
fn sleepUntil(io: std.Io, deadline: ?core.Deadline) std.Io.Cancelable!void {
    const limit = deadline orelse {
        while (true) try io.sleep(.fromSeconds(60 * 60), .awake);
    };
    while (true) {
        const now = std.Io.Clock.awake.now(io);
        if (limit.isExpired(now)) return;
        try io.sleep(limit.remaining(now), .awake);
    }
}

fn writeHead(ptr: *anyopaque, io: std.Io, status: u16, fields: []const h1.Field, body: Exchange.BodyKind) Exchange.WriteError!void {
    return of(ptr).startResponse(io, status, fields, body);
}

fn writeBody(ptr: *anyopaque, io: std.Io, data: []const u8) Exchange.WriteError!void {
    return of(ptr).writeBodyBytes(io, data);
}

fn flush(ptr: *anyopaque, io: std.Io) Exchange.WriteError!void {
    const conn = of(ptr);
    switch (conn.out.state) {
        .head, .body => {},
        else => return conn.misuse("a flush outside a response"),
    }
    if (conn.out.pending.len > 0) try conn.send(io, &.{});
}

fn finish(ptr: *anyopaque, io: std.Io) Exchange.WriteError!void {
    return of(ptr).finishResponse(io);
}

/// Breaks the response: what is not sent stays unsent, and the connection
/// closes, so the client sees the response cut.
fn abort(ptr: *anyopaque, _: std.Io) void {
    const out = &of(ptr).out;
    if (out.state != .finished) out.state = .broken;
}

const testing = std.testing;

test "framingOf: HEAD, 204 and 304 send no body; a stream is chunked on 1.1 and ends with the connection on 1.0" {
    try testing.expectEqual(response.Framing{ .length = 5 }, framingOf(.GET, .http11, 200, .{ .length = 5 }));
    try testing.expectEqual(response.Framing{ .length = 5 }, framingOf(.HEAD, .http11, 200, .{ .length = 5 }));
    try testing.expectEqual(response.Framing.none, framingOf(.GET, .http11, 204, .none));
    try testing.expectEqual(response.Framing.none, framingOf(.GET, .http11, 304, .{ .length = 7 }));
    try testing.expectEqual(response.Framing.chunked, framingOf(.GET, .http11, 200, .stream));
    try testing.expectEqual(response.Framing.until_close, framingOf(.GET, .http10, 200, .stream));
    try testing.expectEqual(response.Framing.none, framingOf(.HEAD, .http11, 200, .stream));
    // A status with a body gets a length even when the server gives none.
    try testing.expectEqual(response.Framing{ .length = 0 }, framingOf(.GET, .http11, 200, .none));
}

test "headBound holds the longest head writeHead writes" {
    const fields = [_]h1.Field{ .{ .name = "content-type", .value = "text/plain" }, .{ .name = "x-a", .value = "" } };
    var buffer: [512]u8 = undefined;
    for ([_]response.Framing{ .none, .{ .length = std.math.maxInt(u64) }, .chunked, .until_close }) |framing| {
        for ([_]h1.Version{ .http10, .http11 }) |version| {
            for ([_]bool{ false, true }) |close| {
                for ([_]u16{ 200, 431, 599 }) |status| {
                    var w: std.Io.Writer = .fixed(&buffer);
                    try response.writeHead(&w, version, status, &fields, framing, close, "Sun, 06 Nov 1994 08:49:37 GMT");
                    try testing.expect(w.buffered().len <= headBound(status, &fields));
                }
            }
        }
    }
}
