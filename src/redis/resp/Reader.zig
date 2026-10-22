//! Reads one reply in RESP3 as a stream of elements. `next` gives one
//! element at a time, its kind and either its value or how many elements
//! it holds, and nothing recurses: a reply nested thousands of levels deep,
//! as a Lua table can be, costs no stack. The reader takes no memory of
//! its own; the bytes of a string go where the caller puts them, or
//! nowhere.
//!
//! - `init(in, budget)` reads from `in`, the buffered reader of the
//!   connection, a reply of at most `budget` bytes on the wire.
//! - `next()` reads the next element. Scalars come whole: null (`_`, and
//!   `$-1` and `*-1` of RESP2), booleans, integers, doubles. A string comes
//!   as its kind, with its length when the header gives one: simple,
//!   bulk and verbatim strings (the latter without its `txt:` prefix,
//!   whose format the element names), errors of both forms, big numbers.
//!   Its bytes are read next with `payloadAlloc`, `payloadPrefix` or
//!   `payloadChunk`, or skipped with `skipPayload`; `next` skips what is
//!   left of them. An aggregate (array, map, set, push) comes with how
//!   many elements it holds, a map with how many pairs: twice as many
//!   elements, each key before its value. Its elements are what the next
//!   calls of `next` return.
//! - `skipElement()` skips what is left of the element `next` returned
//!   last, with all it holds; `skipReply()` skips what is left of the
//!   reply, all of it when nothing was read yet. Neither takes memory.
//! - `done()` tells whether the reply has been read to its end.
//! - `skipAttributes()`, before `next`, skips the attributes at the top of
//!   the reply and leaves its first element unread, for a look at its type
//!   byte.
//! - `nested()` gives a reader of the next element of the aggregate being
//!   read, as a reply of its own, and `rejoin` takes it back: the array of
//!   EXEC holds the replies of the commands of a transaction, and each
//!   command reads its own.
//!
//! What the reader takes care of:
//!
//! - Attributes (`|`) are skipped wherever they stand: neither they nor
//!   their content reach the caller.
//! - A push (`>`) is reported at the top level only, where a server sends
//!   one, between replies; inside a reply it is a ProtocolViolation.
//! - Limits come before memory. Every byte read counts against the
//!   budget, and the length of a string and the number of elements of an
//!   aggregate are checked against what is left of it as soon as their
//!   header is read, before the caller takes memory for them: an element
//!   takes at least 3 bytes, `_\r\n`. More than `max_depth` aggregates
//!   inside each other is ReplyTooLarge too.
//! - Strictness: a known type byte; lengths and integers in decimal, with
//!   no leading zero and within u64 (i64 for integers, which alone may
//!   have a sign); the grammar of RESP3 doubles; no CR or LF inside a
//!   simple string or an error; CRLF after every element. Anything else is
//!   a ProtocolViolation: the stream is out of step, and the connection
//!   must be closed. Streamed strings and aggregates (`$?`, `*?`, `;`,
//!   `.`), which servers do not send, are refused the same way.
//!
//! A reader reads one reply: the next one gets a new reader, with a budget
//! of its own. After an error, the reader and the stream under it are out
//! of step and unusable. The line of a double must fit the buffer of `in`;
//! every other element streams through a buffer of any size.

const std = @import("std");

const Reader = @This();

/// The buffered reader of the connection.
in: *std.Io.Reader,
/// What is left of the reply's budget, in bytes.
budget: usize,
/// How many elements each open aggregate still holds, outermost first. An
/// aggregate stays open until its last element is read whole.
open: [max_depth]usize = undefined,
/// How many aggregates are open.
depth: usize = 0,
/// How many aggregates were open when the element `next` returned last
/// started.
element_depth: usize = 0,
/// The bytes of the last string that are not read yet.
pending: Pending = .none,
/// Whether `next` has read an element of the reply.
started: bool = false,

/// The most aggregates a reply may hold inside each other.
pub const max_depth = 64;

pub const Error = error{
    /// The bytes break RESP3: the stream is out of step.
    ProtocolViolation,
    /// The reply is larger than the budget or nests deeper than
    /// `max_depth`.
    ReplyTooLarge,
    /// The stream ended inside the reply.
    EndOfStream,
    /// Reading failed; the reader under this one knows why.
    ReadFailed,
};

pub const Element = union(enum) {
    /// `_`, and `$-1` and `*-1`, the nulls of RESP2.
    null,
    /// `#t` or `#f`.
    boolean: bool,
    /// `:`, a signed 64-bit integer.
    integer: i64,
    /// `,`, `inf`, `-inf` and `nan` included.
    double: f64,
    /// `+`: its text is the payload.
    simple_string,
    /// `-`: its text, the code first (`WRONGTYPE …`), is the payload.
    simple_error,
    /// `(`: its decimal digits, with a sign if any, are the payload.
    big_number,
    /// `$` and its length; its bytes are the payload.
    bulk_string: usize,
    /// `!`, an error with a length, the code first.
    bulk_error: usize,
    /// `=`: its format and the length of its text, which is the payload.
    verbatim_string: Verbatim,
    /// `*` and how many elements it holds.
    array: usize,
    /// `%` and how many pairs it holds.
    map: usize,
    /// `~` and how many elements it holds.
    set: usize,
    /// `>` and how many elements it holds: data a server sends on its own,
    /// such as a message of a subscription.
    push: usize,
};

/// A verbatim string: its format, `txt` or `mkd`, and the length of the
/// text after `txt:`.
pub const Verbatim = struct {
    format: [3]u8,
    len: usize,
};

/// What `payloadPrefix` read: the start of a string and its whole length.
pub const Prefix = struct {
    /// The first bytes of the string, as many as the buffer holds.
    bytes: []u8,
    /// The length of the whole string.
    len: usize,
};

const Pending = union(enum) {
    none,
    /// The bytes of a bulk string, a bulk error or a verbatim string still
    /// to read, then CRLF; the budget already counts them.
    bulk: usize,
    /// A simple string, a simple error or a big number: bytes up to CRLF.
    line: Line,
};

/// What a line may still hold: any text, or the digits of a big number.
const Line = enum {
    text,
    /// A sign or a digit comes first.
    number,
    /// After the sign: a digit.
    signed_number,
    /// After a digit: more digits, or the end.
    digits,
};

/// The fewest bytes an element takes: `_\r\n`.
const min_element = 3;

/// A reader of one reply from `in` in at most `budget` bytes.
pub fn init(in: *std.Io.Reader, budget: usize) Reader {
    return .{ .in = in, .budget = budget };
}

/// Reads the next element of the reply, past the bytes left of the last
/// string and any attribute before it.
pub fn next(r: *Reader) Error!Element {
    try r.skipPayload();
    // While an attribute is skipped: how many aggregates were open before
    // it. Its elements are read and dropped until the depth is back there.
    var attribute: ?usize = null;
    while (true) {
        const tag = try r.byte();
        if (tag == '|') {
            const pairs = try r.readLength(false) orelse return error.ProtocolViolation;
            const before = attribute orelse r.depth;
            try r.openAggregate(pairs, 2);
            attribute = if (r.depth > before) before else null;
            continue;
        }
        if (tag == '>' and r.depth > 0) return error.ProtocolViolation;
        r.element_depth = r.depth;
        if (r.depth > 0) r.open[r.depth - 1] -= 1;
        r.started = true;
        const element = try r.readElement(tag);
        if (attribute) |before| {
            try r.skipPayload();
            attribute = if (r.depth > before) before else null;
            continue;
        }
        return element;
    }
}

/// Skips the attributes that stand at the top of the reply, before its
/// first element, and leaves that element unread: for the connection,
/// which looks at the first byte of what comes to tell a push between
/// replies from a reply. Call it before `next`.
pub fn skipAttributes(r: *Reader) Error!void {
    std.debug.assert(!r.started);
    while (try r.in.peekByte() == '|') {
        _ = try r.byte();
        const pairs = try r.readLength(false) orelse return error.ProtocolViolation;
        try r.openAggregate(pairs, 2);
        while (r.depth > 0) {
            _ = try r.next();
            try r.skipPayload();
        }
    }
    r.started = false;
}

/// Whether the reply has been read to its end.
pub fn done(r: *const Reader) bool {
    return r.started and r.depth == 0 and r.pending == .none;
}

/// A reader of the next element of the aggregate that `r` holds open,
/// which reads it as a reply of its own: its `skipReply` skips that
/// element only, and `done` tells when it is read. It keeps the rules of
/// the reply that holds it: a push inside is a ProtocolViolation, and the
/// depth and the budget are those of the whole. Give it back to `r` with
/// `rejoin` once it is done, before `r` reads on.
pub fn nested(r: *const Reader) Reader {
    std.debug.assert(r.depth > 0 and r.pending == .none and r.open[r.depth - 1] > 0);
    var element: Reader = .{ .in = r.in, .budget = r.budget, .depth = r.depth };
    // The aggregates that hold the element, closed once it is read: none
    // of them has another element for this reader.
    @memset(element.open[0 .. r.depth - 1], 0);
    element.open[r.depth - 1] = 1;
    return element;
}

/// Takes back `element`, a reader of `nested` that has read its element
/// whole: what it used of the budget, and the place of the element in the
/// aggregate.
pub fn rejoin(r: *Reader, element: *const Reader) void {
    std.debug.assert(element.done());
    r.budget = element.budget;
    r.open[r.depth - 1] -= 1;
    r.complete();
}

/// Skips what is left of the element `next` returned last: the bytes of a
/// string, the elements of an aggregate with all they hold.
pub fn skipElement(r: *Reader) Error!void {
    try r.skipTo(r.element_depth);
}

/// Skips what is left of the reply: all of it when `next` has read
/// nothing yet.
pub fn skipReply(r: *Reader) Error!void {
    if (!r.started) _ = try r.next();
    try r.skipTo(0);
}

fn skipTo(r: *Reader, depth: usize) Error!void {
    try r.skipPayload();
    while (r.depth > depth) {
        _ = try r.next();
        try r.skipPayload();
    }
}

/// Reads the bytes of the last string that are not read yet into memory
/// from `gpa`: all of them, for a string just returned by `next`. Gives an
/// empty slice when there are none.
pub fn payloadAlloc(r: *Reader, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
    switch (r.pending) {
        .none => return gpa.alloc(u8, 0),
        .bulk => |left| {
            const bytes = try gpa.alloc(u8, left);
            errdefer gpa.free(bytes);
            try r.in.readSliceAll(bytes);
            try r.endBulk();
            return bytes;
        },
        .line => {
            var bytes: std.ArrayList(u8) = .empty;
            errdefer bytes.deinit(gpa);
            while (try r.payloadChunk()) |piece| try bytes.appendSlice(gpa, piece);
            return bytes.toOwnedSlice(gpa);
        },
    }
}

/// Copies the first bytes of the last string into `buffer`, as many as it
/// holds, and skips the rest.
pub fn payloadPrefix(r: *Reader, buffer: []u8) Error!Prefix {
    var len: usize = 0;
    while (try r.payloadChunk()) |piece| {
        if (len < buffer.len) {
            const n = @min(piece.len, buffer.len - len);
            @memcpy(buffer[len..][0..n], piece[0..n]);
        }
        len += piece.len;
    }
    return .{ .bytes = buffer[0..@min(len, buffer.len)], .len = len };
}

/// Returns the next piece of the bytes of the last string: a slice of the
/// buffer of `in`, valid until the next read. Null once the string is read
/// to its end, CRLF included.
pub fn payloadChunk(r: *Reader) Error!?[]const u8 {
    switch (r.pending) {
        .none => return null,
        .bulk => |left| {
            if (left == 0) {
                try r.endBulk();
                return null;
            }
            const buffered = try r.in.peekGreedy(1);
            const piece = buffered[0..@min(left, buffered.len)];
            r.in.toss(piece.len);
            r.pending = .{ .bulk = left - piece.len };
            return piece;
        },
        .line => |line| {
            const buffered = try r.in.peekGreedy(1);
            if (buffered[0] == '\r') {
                try r.crlf();
                if (line == .number or line == .signed_number) return error.ProtocolViolation;
                r.pending = .none;
                r.complete();
                return null;
            }
            const end = std.mem.findAny(u8, buffered, "\r\n") orelse buffered.len;
            // A line feed with no carriage return before it.
            if (end == 0) return error.ProtocolViolation;
            const piece = buffered[0..end];
            if (piece.len > r.budget) return error.ReplyTooLarge;
            r.pending = .{ .line = try advance(line, piece) };
            r.budget -= piece.len;
            r.in.toss(piece.len);
            return piece;
        },
    }
}

/// Skips the bytes of the last string that are not read yet.
pub fn skipPayload(r: *Reader) Error!void {
    switch (r.pending) {
        .none => {},
        .bulk => |left| {
            try r.in.discardAll(left);
            try r.endBulk();
        },
        .line => while (try r.payloadChunk()) |_| {},
    }
}

/// Reads the rest of an element whose type byte is `tag`.
fn readElement(r: *Reader, tag: u8) Error!Element {
    switch (tag) {
        '+' => return r.startLine(.simple_string, .text),
        '-' => return r.startLine(.simple_error, .text),
        '(' => return r.startLine(.big_number, .number),
        ':' => {
            const value = try r.readInteger();
            r.complete();
            return .{ .integer = value };
        },
        ',' => {
            const value = try r.readDouble();
            r.complete();
            return .{ .double = value };
        },
        '#' => {
            const value = switch (try r.byte()) {
                't' => true,
                'f' => false,
                else => return error.ProtocolViolation,
            };
            try r.crlf();
            r.complete();
            return .{ .boolean = value };
        },
        '_' => {
            try r.crlf();
            r.complete();
            return .null;
        },
        '$', '!' => {
            const len = try r.readLength(tag == '$') orelse {
                r.complete();
                return .null;
            };
            try r.reserve(len);
            r.pending = .{ .bulk = len };
            return if (tag == '$') .{ .bulk_string = len } else .{ .bulk_error = len };
        },
        '=' => {
            const len = try r.readLength(false) orelse return error.ProtocolViolation;
            if (len < 4) return error.ProtocolViolation;
            try r.reserve(len);
            var format: [3]u8 = undefined;
            for (&format) |*b| b.* = try r.in.takeByte();
            if (try r.in.takeByte() != ':') return error.ProtocolViolation;
            r.pending = .{ .bulk = len - 4 };
            return .{ .verbatim_string = .{ .format = format, .len = len - 4 } };
        },
        '*' => {
            const n = try r.readLength(true) orelse {
                r.complete();
                return .null;
            };
            try r.openAggregate(n, 1);
            return .{ .array = n };
        },
        '%' => {
            const n = try r.readLength(false) orelse return error.ProtocolViolation;
            try r.openAggregate(n, 2);
            return .{ .map = n };
        },
        '~' => {
            const n = try r.readLength(false) orelse return error.ProtocolViolation;
            try r.openAggregate(n, 1);
            return .{ .set = n };
        },
        '>' => {
            const n = try r.readLength(false) orelse return error.ProtocolViolation;
            try r.openAggregate(n, 1);
            return .{ .push = n };
        },
        else => return error.ProtocolViolation,
    }
}

fn startLine(r: *Reader, comptime element: std.meta.Tag(Element), line: Line) Element {
    r.pending = .{ .line = line };
    return element;
}

/// Opens an aggregate of `n` entries of `per` elements each. They must be
/// able to fit what is left of the budget, at `min_element` bytes each,
/// and the aggregate must stand within `max_depth`, even when empty.
fn openAggregate(r: *Reader, n: usize, per: usize) Error!void {
    const elements = std.math.mul(usize, n, per) catch return error.ReplyTooLarge;
    if (elements > r.budget / min_element) return error.ReplyTooLarge;
    if (r.depth == max_depth) return error.ReplyTooLarge;
    if (elements == 0) {
        r.complete();
        return;
    }
    r.open[r.depth] = elements;
    r.depth += 1;
}

/// Closes the aggregates whose last element has just been read whole.
fn complete(r: *Reader) void {
    while (r.depth > 0 and r.open[r.depth - 1] == 0) r.depth -= 1;
}

/// Counts a string of `len` bytes and its CRLF in the budget.
fn reserve(r: *Reader, len: usize) Error!void {
    if (len > r.budget or r.budget - len < 2) return error.ReplyTooLarge;
    r.budget -= len + 2;
}

/// Reads the CRLF after the bytes of a string, which the budget already
/// counts, and ends the string.
fn endBulk(r: *Reader) Error!void {
    r.pending = .none;
    if (try r.in.takeByte() != '\r' or try r.in.takeByte() != '\n') return error.ProtocolViolation;
    r.complete();
}

/// Reads one byte and counts it in the budget.
fn byte(r: *Reader) Error!u8 {
    if (r.budget == 0) return error.ReplyTooLarge;
    const b = try r.in.takeByte();
    r.budget -= 1;
    return b;
}

fn crlf(r: *Reader) Error!void {
    if (try r.byte() != '\r' or try r.byte() != '\n') return error.ProtocolViolation;
}

/// Reads a length and its CRLF; null for `-1`, the null of RESP2, where
/// `nullable` allows it.
fn readLength(r: *Reader, nullable: bool) Error!?usize {
    const first = try r.byte();
    if (first == '-') {
        if (!nullable or try r.byte() != '1') return error.ProtocolViolation;
        try r.crlf();
        return null;
    }
    const value = try r.readDigits(first);
    return std.math.cast(usize, value) orelse error.ReplyTooLarge;
}

/// Reads an integer and its CRLF: a sign if any, then digits.
fn readInteger(r: *Reader) Error!i64 {
    var first = try r.byte();
    const negative = first == '-';
    if (first == '-' or first == '+') first = try r.byte();
    const magnitude: i128 = try r.readDigits(first);
    return std.math.cast(i64, if (negative) -magnitude else magnitude) orelse error.ProtocolViolation;
}

/// Reads the digits of a number whose first byte is `first`, and its
/// CRLF: no leading zero, at most what u64 holds.
fn readDigits(r: *Reader, first: u8) Error!u64 {
    if (!std.ascii.isDigit(first)) return error.ProtocolViolation;
    var value: u64 = first - '0';
    while (true) {
        const b = try r.byte();
        if (b == '\r') break;
        if (!std.ascii.isDigit(b) or value == 0) return error.ProtocolViolation;
        value = std.math.mul(u64, value, 10) catch return error.ProtocolViolation;
        value = std.math.add(u64, value, b - '0') catch return error.ProtocolViolation;
    }
    if (try r.byte() != '\n') return error.ProtocolViolation;
    return value;
}

/// Reads a double and its CRLF. Its line must fit the buffer of `in`.
fn readDouble(r: *Reader) Error!f64 {
    const line = r.in.peekDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.ProtocolViolation,
        error.EndOfStream, error.ReadFailed => |e| return e,
    };
    if (line.len > r.budget) return error.ReplyTooLarge;
    if (line.len < 2 or line[line.len - 2] != '\r') return error.ProtocolViolation;
    const text = line[0 .. line.len - 2];
    if (!isDouble(text)) return error.ProtocolViolation;
    const value = std.fmt.parseFloat(f64, text) catch return error.ProtocolViolation;
    r.budget -= line.len;
    r.in.toss(line.len);
    return value;
}

/// Whether `text` is a double of RESP3: `inf` or `nan`, or digits with a
/// fraction and an exponent if any, all after a sign if any. The decoder
/// takes the same grammar from a string that holds a number.
pub fn isDouble(text: []const u8) bool {
    const unsigned = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    if (std.mem.eql(u8, unsigned, "inf") or std.mem.eql(u8, unsigned, "nan")) return true;
    var i = digitsEnd(unsigned, 0);
    if (i == 0) return false;
    if (i < unsigned.len and unsigned[i] == '.') {
        const end = digitsEnd(unsigned, i + 1);
        if (end == i + 1) return false;
        i = end;
    }
    if (i < unsigned.len and (unsigned[i] == 'e' or unsigned[i] == 'E')) {
        i += 1;
        if (i < unsigned.len and (unsigned[i] == '-' or unsigned[i] == '+')) i += 1;
        const end = digitsEnd(unsigned, i);
        if (end == i) return false;
        i = end;
    }
    return i == unsigned.len;
}

fn digitsEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return i;
}

/// Checks `piece`, the next bytes of a line, against what the line may
/// still hold, and returns what it may hold after them.
fn advance(line: Line, piece: []const u8) Error!Line {
    var state = line;
    for (piece) |c| {
        state = switch (state) {
            .text => return .text,
            .number => if (c == '-' or c == '+') .signed_number else if (std.ascii.isDigit(c)) .digits else return error.ProtocolViolation,
            .signed_number, .digits => if (std.ascii.isDigit(c)) .digits else return error.ProtocolViolation,
        };
    }
    return state;
}
