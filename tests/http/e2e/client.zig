//! A raw HTTP/1.1 client for the end-to-end tests, on zio: it sends the
//! bytes it is given as they are and reads responses as they come, each
//! read within a time limit, so a test sees exactly what the server put on
//! the wire: the status line, every field in its order and case, and the
//! body by its length, chunked or up to the end of the connection.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// A field of a response as it came.
pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16,
    reason: []const u8,
    headers: []const Header,
    body: []const u8,

    /// The value of the first field `name`, in any case.
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// How many fields are named `name`, in any case.
    pub fn count(r: *const Response, name: []const u8) usize {
        var n: usize = 0;
        for (r.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) n += 1;
        }
        return n;
    }
};

pub const Error = error{
    /// Nothing more came within the time.
    Timeout,
    /// The server closed the connection before the response ended.
    EndOfStream,
    /// The response breaks HTTP/1.1, or does not fit the buffer.
    BadResponse,
    ConnectionResetByPeer,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
} || Io.Cancelable;

pub const ReadOptions = struct {
    /// The request was HEAD: the response has no body.
    head_request: bool = false,
    /// For the whole response.
    timeout: Io.Duration = .fromSeconds(5),
};

pub const Client = struct {
    stream: net.Stream,
    gpa: std.mem.Allocator,
    /// Bytes read and not yet part of a response read.
    buffer: []u8,
    len: usize = 0,
    closed: bool = false,

    /// Connects to `port` on 127.0.0.1.
    pub fn connect(io: Io, gpa: std.mem.Allocator, port: u16) !Client {
        const address: net.IpAddress = try .parseIp4("127.0.0.1", port);
        const stream = try address.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);
        return .{ .stream = stream, .gpa = gpa, .buffer = try gpa.alloc(u8, 1 << 20) };
    }

    /// Closes the connection; a second call does nothing.
    pub fn close(c: *Client, io: Io) void {
        if (c.closed) return;
        c.closed = true;
        c.stream.close(io);
        c.gpa.free(c.buffer);
    }

    /// Sends all of `bytes`.
    pub fn send(c: *Client, io: Io, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            const result = try io.operate(.{ .net_write = .{ .socket_handle = c.stream.socket.handle, .data = &.{rest} } });
            const n = result.net_write catch return error.WriteFailed;
            rest = rest[n..];
        }
    }

    /// Ends the client's side of the connection; it still reads.
    pub fn shutdownSend(c: *Client, io: Io) !void {
        try c.stream.shutdown(io, .send);
    }

    /// Reads more into the buffer, by `deadline`. `error.EndOfStream` when
    /// the server has closed.
    fn fill(c: *Client, io: Io, deadline: Io.Clock.Timestamp) Error!void {
        if (c.len == c.buffer.len) return error.BadResponse;
        var data: [1][]u8 = .{c.buffer[c.len..]};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = c.stream.socket.handle, .data = &data } }, .{ .deadline = deadline }) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.ConcurrencyUnavailable => error.ReadFailed,
        };
        const read = result.net_read catch |err| return switch (err) {
            error.ConnectionResetByPeer => error.ConnectionResetByPeer,
            else => error.ReadFailed,
        };
        if (read.data_len == 0) return error.EndOfStream;
        c.len += read.data_len;
    }

    /// Waits up to `timeout` for bytes from the server, and keeps them for
    /// `readResponse`: true when some came.
    pub fn waitData(c: *Client, io: Io, timeout: Io.Duration) Error!bool {
        if (c.len > 0) return true;
        c.fill(io, .fromNow(io, .{ .raw = timeout, .clock = .awake })) catch |err| switch (err) {
            error.Timeout => return false,
            else => |e| return e,
        };
        return true;
    }

    /// Reads until the bytes kept hold `needle`, `timeout` at most, and
    /// keeps them for `readResponse`: false when they did not come.
    pub fn readUntil(c: *Client, io: Io, needle: []const u8, timeout: Io.Duration) Error!bool {
        const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = timeout, .clock = .awake });
        while (std.mem.find(u8, c.buffer[0..c.len], needle) == null) {
            c.fill(io, deadline) catch |err| switch (err) {
                error.Timeout => return false,
                else => |e| return e,
            };
        }
        return true;
    }

    /// The bytes kept and not yet part of a response read.
    pub fn kept(c: *const Client) []const u8 {
        return c.buffer[0..c.len];
    }

    fn consume(c: *Client, n: usize) void {
        std.mem.copyForwards(u8, c.buffer[0 .. c.len - n], c.buffer[n..c.len]);
        c.len -= n;
    }

    /// Reads the next response; its strings live in `arena`.
    pub fn readResponse(c: *Client, io: Io, arena: std.mem.Allocator, options: ReadOptions) Error!Response {
        const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = options.timeout, .clock = .awake });
        const head_len = while (true) {
            if (std.mem.find(u8, c.buffer[0..c.len], "\r\n\r\n")) |end| break end + 4;
            try c.fill(io, deadline);
        };
        const head = try arena.dupe(u8, c.buffer[0..head_len]);
        c.consume(head_len);

        var lines = std.mem.splitSequence(u8, head[0 .. head.len - 4], "\r\n");
        const status_line = lines.first();
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") or status_line.len < 13 or status_line[12] != ' ')
            return error.BadResponse;
        const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;
        var headers: std.ArrayList(Header) = .empty;
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadResponse;
            try headers.append(arena, .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") });
        }
        var res: Response = .{ .status = status, .reason = status_line[13..], .headers = headers.items, .body = "" };

        if (options.head_request or status < 200 or status == 204 or status == 304) return res;
        if (res.header("transfer-encoding")) |coding| {
            if (!std.ascii.eqlIgnoreCase(coding, "chunked")) return error.BadResponse;
            res.body = try c.readChunked(io, arena, deadline);
        } else if (res.header("content-length")) |text| {
            const length = std.fmt.parseInt(usize, text, 10) catch return error.BadResponse;
            while (c.len < length) try c.fill(io, deadline);
            res.body = try arena.dupe(u8, c.buffer[0..length]);
            c.consume(length);
        } else {
            // To the end of the connection.
            while (true) c.fill(io, deadline) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            res.body = try arena.dupe(u8, c.buffer[0..c.len]);
            c.consume(c.len);
        }
        return res;
    }

    fn readChunked(c: *Client, io: Io, arena: std.mem.Allocator, deadline: Io.Clock.Timestamp) Error![]const u8 {
        var body: std.ArrayList(u8) = .empty;
        while (true) {
            const line_end = while (true) {
                if (std.mem.find(u8, c.buffer[0..c.len], "\r\n")) |end| break end;
                try c.fill(io, deadline);
            };
            const size = std.fmt.parseInt(usize, c.buffer[0..line_end], 16) catch return error.BadResponse;
            c.consume(line_end + 2);
            if (size == 0) {
                // No trailers: the empty line ends the body.
                while (c.len < 2) try c.fill(io, deadline);
                if (!std.mem.eql(u8, c.buffer[0..2], "\r\n")) return error.BadResponse;
                c.consume(2);
                return body.items;
            }
            while (c.len < size + 2) try c.fill(io, deadline);
            try body.appendSlice(arena, c.buffer[0..size]);
            if (!std.mem.eql(u8, c.buffer[size..][0..2], "\r\n")) return error.BadResponse;
            c.consume(size + 2);
        }
    }

    /// Expects the server to end the connection within `timeout`, with no
    /// byte before: the end of the stream, or a reset.
    pub fn expectEnd(c: *Client, io: Io, timeout: Io.Duration) !void {
        if (c.len > 0) {
            std.debug.print("expected the end of the connection, got {d} bytes: {s}\n", .{ c.len, c.buffer[0..@min(c.len, 200)] });
            return error.TestUnexpectedBytes;
        }
        c.fill(io, .fromNow(io, .{ .raw = timeout, .clock = .awake })) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer => return,
            error.Timeout => return error.TestConnectionStillOpen,
            else => |e| return e,
        };
        std.debug.print("expected the end of the connection, got {d} bytes: {s}\n", .{ c.len, c.buffer[0..@min(c.len, 200)] });
        return error.TestUnexpectedBytes;
    }
};
