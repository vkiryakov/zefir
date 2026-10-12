//! Incremental parser of what a NATS server sends (spec R23, R24). Pure:
//! bytes in, frames out; no I/O, no allocation.
//!
//! The reader passes the bytes it has buffered to `next`. The slices of a
//! frame point into those bytes and stay valid until the reader drops the
//! `consumed` ones. A null frame means "need more": keep
//! `input[consumed..]`, read more after it and call again.
//!
//! A message comes as `.msg` (its control line), then its bytes in one or
//! more `.body` frames (header block first, then payload; none when both
//! are empty), then `.msg_end` once the CRLF after it is checked. The reader
//! allocates the message on `.msg`, or skips the bodies of a message that is
//! over its limits without allocating anything.
//!
//! After an error the stream is out of step: drop the connection.

const std = @import("std");
const Parser = @This();

pub const Limits = struct {
    /// The longest line other than INFO, CRLF not counted.
    max_control_line: usize = 4096,
    /// The longest INFO line, CRLF not counted: INFO lists the cluster.
    max_info_line: usize = 64 * 1024,
};

pub const Error = error{
    /// No line end within the limit.
    LineTooLong,
    /// An operation a server does not send.
    UnknownOperation,
    /// Wrong arguments: their number, a size or sid that is not plain
    /// decimal digits or overflows, a header size over the total size.
    InvalidArguments,
    /// The two bytes after a message are not CRLF.
    MissingTerminator,
};

/// The control line of MSG (no headers) or HMSG.
pub const Msg = struct {
    subject: []const u8,
    sid: u64,
    reply_to: ?[]const u8,
    /// Bytes of the header block; 0 for MSG.
    header_len: u32,
    /// The header block plus the payload.
    total_len: u32,
};

pub const Frame = union(enum) {
    /// The JSON of an INFO line.
    info: []const u8,
    msg: Msg,
    /// The next bytes of the current message.
    body: []const u8,
    /// The current message is complete.
    msg_end,
    ping,
    pong,
    /// `+OK`; a server sends it only to `verbose` clients.
    ok,
    /// The text of `-ERR` without its quotes.
    err: []const u8,
};

pub const Step = struct {
    /// Bytes of the input this call used.
    consumed: usize,
    /// Null: more input is needed.
    frame: ?Frame,
};

const State = union(enum) {
    line,
    /// Bytes of the current message still to come.
    body: u32,
    /// The CRLF after a message is next.
    end,
};

limits: Limits,
state: State = .line,

pub fn init(limits: Limits) Parser {
    return .{ .limits = limits };
}

pub fn next(p: *Parser, input: []const u8) Error!Step {
    switch (p.state) {
        .line => return p.nextLine(input),
        .body => |left| {
            if (input.len == 0) return .{ .consumed = 0, .frame = null };
            const n: u32 = @intCast(@min(input.len, @as(usize, left)));
            p.state = if (n == left) .end else .{ .body = left - n };
            return .{ .consumed = n, .frame = .{ .body = input[0..n] } };
        },
        .end => {
            if (input.len > 0 and input[0] != '\r') return error.MissingTerminator;
            if (input.len < 2) return .{ .consumed = 0, .frame = null };
            if (input[1] != '\n') return error.MissingTerminator;
            p.state = .line;
            return .{ .consumed = 2, .frame = .msg_end };
        },
    }
}

fn nextLine(p: *Parser, input: []const u8) Error!Step {
    // INFO has a limit of its own; the first four bytes tell which applies.
    const is_info = input.len >= 4 and std.ascii.eqlIgnoreCase(input[0..4], "INFO");
    const limit = if (is_info) p.limits.max_info_line else p.limits.max_control_line;
    // A line may take `limit` bytes, then CR and LF.
    const window = input[0..@min(input.len, limit +| 2)];
    const lf = std.mem.findScalar(u8, window, '\n') orelse {
        if (window.len == limit +| 2) return error.LineTooLong;
        return .{ .consumed = 0, .frame = null };
    };
    var line = input[0..lf];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len > limit) return error.LineTooLong;

    const frame = try parseLine(line);
    if (frame == .msg) {
        const total = frame.msg.total_len;
        p.state = if (total == 0) .end else .{ .body = total };
    }
    return .{ .consumed = lf + 1, .frame = frame };
}

fn parseLine(line: []const u8) Error!Frame {
    const op_end = std.mem.findAny(u8, line, " \t") orelse line.len;
    const op = line[0..op_end];
    const args = std.mem.trim(u8, line[op_end..], " \t");
    if (std.ascii.eqlIgnoreCase(op, "MSG")) return .{ .msg = try parseMsg(args, false) };
    if (std.ascii.eqlIgnoreCase(op, "HMSG")) return .{ .msg = try parseMsg(args, true) };
    if (std.ascii.eqlIgnoreCase(op, "PING")) return if (args.len == 0) .ping else error.InvalidArguments;
    if (std.ascii.eqlIgnoreCase(op, "PONG")) return if (args.len == 0) .pong else error.InvalidArguments;
    if (std.ascii.eqlIgnoreCase(op, "+OK")) return if (args.len == 0) .ok else error.InvalidArguments;
    if (std.ascii.eqlIgnoreCase(op, "INFO")) return if (args.len > 0) .{ .info = args } else error.InvalidArguments;
    if (std.ascii.eqlIgnoreCase(op, "-ERR")) return .{ .err = unquote(args) };
    return error.UnknownOperation;
}

/// `'text'` becomes `text`; text without both quotes stays as it is.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') return text[1 .. text.len - 1];
    return text;
}

/// MSG: `subject sid [reply-to] size`; HMSG: `subject sid [reply-to] header-size total-size`.
fn parseMsg(args: []const u8, headers: bool) Error!Msg {
    var tokens: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |token| {
        if (count == tokens.len) return error.InvalidArguments;
        tokens[count] = token;
        count += 1;
    }
    const sizes: usize = if (headers) 2 else 1;
    if (count != 2 + sizes and count != 3 + sizes) return error.InvalidArguments;
    const total_len = try parseNumber(u32, tokens[count - 1]);
    const header_len = if (headers) try parseNumber(u32, tokens[count - 2]) else 0;
    if (header_len > total_len) return error.InvalidArguments;
    return .{
        .subject = tokens[0],
        .sid = try parseNumber(u64, tokens[1]),
        .reply_to = if (count == 3 + sizes) tokens[2] else null,
        .header_len = header_len,
        .total_len = total_len,
    };
}

/// Plain decimal digits: no sign, no `_`, no `0x`; overflow is an error.
fn parseNumber(comptime T: type, text: []const u8) Error!T {
    if (text.len == 0) return error.InvalidArguments;
    var n: T = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidArguments;
        n = std.math.mul(T, n, 10) catch return error.InvalidArguments;
        n = std.math.add(T, n, c - '0') catch return error.InvalidArguments;
    }
    return n;
}

const testing = std.testing;
const golden = @import("golden.zig");

/// Feeds `input` to a parser the way a reader with a buffer would: `first`
/// bytes, then `chunk` bytes at a time. Writes one line per frame; bodies in
/// a row are joined, so the text does not depend on how the input was cut.
fn transcript(input: []const u8, first: usize, chunk: usize, limits: Limits, out: *std.Io.Writer) !void {
    var parser: Parser = .init(limits);
    var window: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    var fed: usize = 0;
    var piece = first;
    var in_body = false;
    while (true) {
        while (true) {
            const step = parser.next(window[0..len]) catch |err| {
                if (in_body) try out.writeAll("\n");
                try out.print("ERROR {t}\n", .{err});
                return;
            };
            if (step.frame) |frame| {
                if (frame != .body and in_body) {
                    try out.writeAll("\n");
                    in_body = false;
                }
                switch (frame) {
                    .info => |json| try out.print("INFO {s}\n", .{json}),
                    .msg => |m| try out.print("MSG {s} {d} {s} {d} {d}\n", .{ m.subject, m.sid, m.reply_to orelse "-", m.header_len, m.total_len }),
                    .body => |bytes| {
                        if (!in_body) try out.writeAll("BODY ");
                        in_body = true;
                        try out.print("{f}", .{std.zig.fmtString(bytes)});
                    },
                    .msg_end => try out.writeAll("END\n"),
                    .ping => try out.writeAll("PING\n"),
                    .pong => try out.writeAll("PONG\n"),
                    .ok => try out.writeAll("OK\n"),
                    .err => |text| try out.print("ERR {s}\n", .{text}),
                }
            } else if (step.consumed == 0) break;
            // Every frame uses at least one byte, so the loop always ends.
            try testing.expect(step.consumed > 0);
            std.mem.copyForwards(u8, window[0 .. len - step.consumed], window[step.consumed..len]);
            len -= step.consumed;
        }
        if (fed == input.len) {
            if (in_body) try out.writeAll("\n");
            if (len > 0 or parser.state != .line) try out.print("INCOMPLETE {d}\n", .{len});
            return;
        }
        const n = @min(piece, input.len - fed);
        piece = chunk;
        if (len + n > window.len) return error.TestWindowTooSmall;
        @memcpy(window[len..][0..n], input[fed..][0..n]);
        len += n;
        fed += n;
    }
}

fn expectTranscript(expected: []const u8, input: []const u8) !void {
    try expectTranscriptWith(expected, input, .{});
}

fn expectTranscriptWith(expected: []const u8, input: []const u8, limits: Limits) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try transcript(input, input.len, input.len, limits, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "golden frames from nats-server 2.15.1" {
    try expectTranscript("INFO " ++ golden.info_default_json ++ "\n", golden.info_default);
    try expectTranscript("MSG foo 1 - 0 5\nBODY hello\nEND\n", golden.msg_plain);
    try expectTranscript("MSG foo 1 reply.to.me 0 5\nBODY world\nEND\n", golden.msg_reply);
    try expectTranscript("MSG foo.bar 2 - 0 0\nEND\n", golden.msg_empty);
    try expectTranscript("MSG h.test 4 - 53 61\nBODY NATS/1.0\\r\\nX-Multi: one\\r\\nX-Multi: two\\r\\nX-Single: v\\r\\n\\r\\npayload!\nEND\n", golden.hmsg_multi);
    try expectTranscript("MSG h.test 4 reply.h 32 32\nBODY NATS/1.0\\r\\nX-Only-Header: yes\\r\\n\\r\\n\nEND\n", golden.hmsg_header_only);
    try expectTranscript("MSG _INBOX.spike.1 5 - 46 46\nBODY NATS/1.0 503\\r\\nNats-Subject: nobody.listens\\r\\n\\r\\n\nEND\n", golden.hmsg_no_responders);
    try expectTranscript("PING\nPONG\n", golden.ping ++ golden.pong);
    try expectTranscript("ERR Authorization Violation\n", golden.err_authorization);
    try expectTranscript("ERR Permissions Violation for Publish to \"secret.x\"\n", golden.err_publish_permission);
}

test "the recorded session gives the same frames however it is cut" {
    const session = golden.session;
    var whole: std.Io.Writer.Allocating = .init(testing.allocator);
    defer whole.deinit();
    try transcript(session, session.len, session.len, .{}, &whole.writer);
    try testing.expect(std.mem.find(u8, whole.written(), "ERROR") == null);
    try testing.expect(std.mem.find(u8, whole.written(), "INCOMPLETE") == null);

    // Two pieces, cut at every byte.
    for (0..session.len + 1) |cut| {
        var parts: std.Io.Writer.Allocating = .init(testing.allocator);
        defer parts.deinit();
        try transcript(session, cut, session.len, .{}, &parts.writer);
        try testing.expectEqualStrings(whole.written(), parts.written());
    }
    // Pieces of 1 to 64 bytes; 1 is byte by byte.
    for (1..65) |chunk| {
        var parts: std.Io.Writer.Allocating = .init(testing.allocator);
        defer parts.deinit();
        try transcript(session, chunk, chunk, .{}, &parts.writer);
        try testing.expectEqualStrings(whole.written(), parts.written());
    }
}

test "lenient forms a server may send" {
    // Operation names in any case, runs of spaces and tabs, a bare LF.
    try expectTranscript("MSG foo 1 - 0 5\nBODY hello\nEND\nPING\nPONG\nOK\nERR x\n", "msg\tfoo  1 \t5 \r\nhello\r\nping\npOnG\r\n+ok\r\n-err 'x'\r\n");
    try expectTranscript("INFO {}\n", "info  {} \r\n");
    // -ERR without quotes, and a quote inside the text.
    try expectTranscript("ERR plain text\nERR it's\n", "-ERR plain text\r\n-ERR 'it's'\r\n");
}

test "payload bytes that look like frames are payload" {
    try expectTranscript("MSG a 1 - 0 15\nBODY \\r\\nMSG foo 1 5\\r\\n\nEND\nPONG\n", "MSG a 1 15\r\n\r\nMSG foo 1 5\r\n\r\nPONG\r\n");
    // Every byte value, CR and LF among them.
    const binary = comptime all: {
        var bytes: [256]u8 = undefined;
        for (&bytes, 0..) |*b, i| b.* = @intCast(i);
        break :all bytes;
    };
    var parser: Parser = .init(.{});
    var rest: []const u8 = "MSG bin 7 256\r\n" ++ binary ++ "\r\n";
    var got: [256]u8 = undefined;
    var got_len: usize = 0;
    while (rest.len > 0) {
        const step = try parser.next(rest);
        if (step.consumed == 0) return error.TestUnexpectedNeedMore;
        if (step.frame) |frame| {
            if (frame == .body) {
                @memcpy(got[got_len..][0..frame.body.len], frame.body);
                got_len += frame.body.len;
            }
        }
        rest = rest[step.consumed..];
    }
    try testing.expectEqualSlices(u8, &binary, got[0..got_len]);
}

test "line limits: exactly at the limit passes, one byte more fails" {
    const subject: [4096 - "MSG ".len - " 1 0".len]u8 = @splat('a');
    try expectTranscript("MSG " ++ subject ++ " 1 - 0 0\nEND\n", "MSG " ++ subject ++ " 1 0\r\n\r\n");
    try expectTranscript("ERROR LineTooLong\n", "MSG " ++ subject ++ "a 1 0\r\n\r\n");
    try expectTranscript("ERROR LineTooLong\n", "MSG " ++ subject ++ "a 1 0\n\r\n");

    const small: Limits = .{ .max_control_line = 16, .max_info_line = 32 };
    try expectTranscriptWith("PING\nERROR LineTooLong\n", "PING\r\nMSG abcdefgh 1 01\r\n\r\n", small);
    try expectTranscriptWith("MSG abcdefgh 1 - 0 0\nEND\n", "MSG abcdefgh 1 0\r\n\r\n", small);
    const info: [32 - "INFO ".len]u8 = @splat('x');
    try expectTranscriptWith("INFO " ++ info ++ "\n", "INFO " ++ info ++ "\r\n", small);
    try expectTranscriptWith("ERROR LineTooLong\n", "INFO " ++ info ++ "x\r\n", small);
    // Without a line end the parser waits until the limit is reached, then fails.
    try expectTranscriptWith("INCOMPLETE 17\n", "MSG abcdefgh 1 01", small);
    try expectTranscriptWith("ERROR LineTooLong\n", "MSG abcdefgh 1 012", small);
}

test "malformed frames" {
    for ([_][2][]const u8{
        .{ "FOO bar\r\n", "ERROR UnknownOperation\n" },
        .{ "\r\n", "ERROR UnknownOperation\n" },
        .{ " PING\r\n", "ERROR UnknownOperation\n" },
        .{ "PUB foo 1\r\nx\r\n", "ERROR UnknownOperation\n" },
        .{ "MSG foo\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 r 5 6\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo x 5\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 5a\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 -5\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 +5\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 1_0\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 0x10\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 4294967296\r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 18446744073709551616 1\r\n", "ERROR InvalidArguments\n" },
        .{ "HMSG foo 1 5\r\n", "ERROR InvalidArguments\n" },
        .{ "HMSG foo 1 10 5\r\n", "ERROR InvalidArguments\n" },
        .{ "PING extra\r\n", "ERROR InvalidArguments\n" },
        .{ "INFO\r\n", "ERROR InvalidArguments\n" },
        .{ "INFO  \r\n", "ERROR InvalidArguments\n" },
        .{ "MSG foo 1 5\r\nhelloXY", "MSG foo 1 - 0 5\nBODY hello\nERROR MissingTerminator\n" },
        .{ "MSG foo 1 5\r\nhello\rX", "MSG foo 1 - 0 5\nBODY hello\nERROR MissingTerminator\n" },
        .{ "MSG foo 1 0\r\nX", "MSG foo 1 - 0 0\nERROR MissingTerminator\n" },
    }) |case| {
        try expectTranscript(case[1], case[0]);
    }
}

test "the largest sizes parse, and a message may stop half way" {
    try expectTranscript("MSG s 18446744073709551615 - 0 4294967295\nBODY abc\nINCOMPLETE 0\n", "MSG s 18446744073709551615 4294967295\r\nabc");
    try expectTranscript("MSG s 1 - 0 3\nBODY abc\nINCOMPLETE 1\n", "MSG s 1 3\r\nabc\r");
    try expectTranscript("INCOMPLETE 8\n", "MSG s 1 ");
}
