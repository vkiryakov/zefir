//! The errors of the client, and what the client or the server said about
//! one.
//!
//! - `Error` — the closed set of 16 names that the client, `redis.Conn`,
//!   the subscriber and the iterator return.
//! - `CommandError` — the errors of one command of a pipeline or a
//!   transaction, which come as values in its place of the result:
//!   `ServerError` and `UnexpectedReply`. They are in `Error`, so `try r[0]`
//!   works in a function that returns `redis.Error!T`.
//! - `outcome` — whether the server may have run the command:
//!   `.not_sent` is safe to retry, `.may_have_executed` only for a command
//!   that may run twice. Safe is not the same as worth it: of the
//!   `.not_sent` errors, `Unavailable` and `PoolExhausted` may go through
//!   later, `DeadlineExceeded` and `Cancelled` only with a new context, and
//!   `InvalidArgument`, `Unsupported`, `Closed` and `AuthenticationFailed`
//!   fail the same way again. Nothing in zefir retries by itself.
//! - `Diagnostics` — the details of one error, for logs: where it
//!   happened, the error of std underneath, the server's code and text or
//!   the client's text, and for a pipeline or a transaction the command it
//!   is about.
//!
//! A `ServerError` may have executed: an error in the middle of a Lua
//! script leaves the writes it made. Some codes say that the command did
//! not run at all, since the server checks them before it runs one:
//! `NOAUTH`, `NOPERM`, `OOM`, `MISCONF`, `NOREPLICAS`, `READONLY`,
//! `MASTERDOWN`, `LOADING`, `BUSY`, and `EXECABORT` of a transaction
//! dropped whole. With them the caller may make even a command that is not
//! idempotent again; `outcome` still says `.may_have_executed`, since the
//! class belongs to the name of the error, and `diagnostics.isCode` tells
//! the rest.
//!
//! ```zig
//! var diagnostics: redis.Diagnostics = .{};
//! const left = client.run(io, op, cmd.decr("stock:coffee"), .{ .diagnostics = &diagnostics }) catch |err| {
//!     log.warn("{t}: {s}", .{ err, diagnostics.message() });
//!     if (err == error.ServerError and diagnostics.isCode("WRONGTYPE")) return error.NotACounter;
//!     return err;
//! };
//! ```

const std = @import("std");

/// What can go wrong in a call. Each name says whether the server may have
/// run the command; `outcome` tells it in code.
pub const Error = error{
    /// The call breaks a rule of the client: bad options or URL, an empty
    /// list, a duration under 1 ms, NaN, a command that changes the state
    /// of the connection in `cmd.raw`, a reply that needs memory without
    /// an allocator, a database of the URL that the server lacks. Not sent.
    InvalidArgument,
    /// What v0.1 does not do: `rediss://`, parameters of the URL, UNIX
    /// sockets; a server other than Redis 7.2 or later and Valkey 8 or
    /// later, without RESP3, in cluster or sentinel mode. Not sent.
    Unsupported,
    /// The client or the subscriber is closed, or the `redis.Conn` lost its
    /// connection with an error before. Not sent.
    Closed,
    /// No connection: DNS, TCP or HELLO failed, the server is full or in
    /// protected mode, the pool is paused after a clear, or `connect` has
    /// not succeeded. Not sent.
    Unavailable,
    /// The server refused the user or the password (`WRONGPASS`), or wants
    /// a password that was not given (`NOAUTH`). Not sent.
    AuthenticationFailed,
    /// The deadline ran out in the queue of the pool. Not sent.
    PoolExhausted,
    /// The deadline left less than 1 ms, or less than a round trip, before
    /// sending; a blocking command had too little left for its margin; or
    /// the deadline passed while a connection opened. Not sent.
    DeadlineExceeded,
    /// The token or the task was canceled before sending. Not sent.
    Cancelled,
    /// The connection broke after the command started to go out, or `close`
    /// cut the exchange, or a subscriber lost its connection. May have
    /// executed.
    ConnectionLost,
    /// The deadline passed after the command went out. May have executed.
    Timeout,
    /// The task was canceled while the command was out. May have executed.
    Interrupted,
    /// The reply broke RESP3. May have executed; the connection is closed.
    ProtocolViolation,
    /// The reply is larger than `max_reply_bytes` or nests deeper than 64
    /// levels. May have executed; the connection is closed.
    ReplyTooLarge,
    /// The server answered with an error; its code and text are in
    /// `Diagnostics`. May have executed.
    ServerError,
    /// The reply does not fit the type the call named, such as `abc` for an
    /// `i64`. May have executed; the reply was read to its end and the
    /// connection stays.
    UnexpectedReply,
    /// Always may have executed: the caller cannot tell where memory ran
    /// out.
    OutOfMemory,
};

/// The errors of one command of a pipeline or a transaction: the value in
/// its place of the result, while the other commands go on.
pub const CommandError = error{ ServerError, UnexpectedReply };

/// Whether a command that failed may have run on the server.
pub const Outcome = enum {
    /// Nothing reached the server: the call is safe to make again. It goes
    /// through only once what failed it has changed: the server is back or
    /// a connection free (`Unavailable`, `PoolExhausted`), or the context
    /// is new (`DeadlineExceeded`, `Cancelled`). The rest fail the same way
    /// again.
    not_sent,
    /// The server may have run it, wholly or in part: make it again only if
    /// running it twice is safe.
    may_have_executed,
};

/// The class of `err`. The switch is the table: a new name of `Error`
/// stops the build until it has a class.
pub fn outcome(err: Error) Outcome {
    return switch (err) {
        error.InvalidArgument,
        error.Unsupported,
        error.Closed,
        error.Unavailable,
        error.AuthenticationFailed,
        error.PoolExhausted,
        error.DeadlineExceeded,
        error.Cancelled,
        => .not_sent,
        error.ConnectionLost,
        error.Timeout,
        error.Interrupted,
        error.ProtocolViolation,
        error.ReplyTooLarge,
        error.ServerError,
        error.UnexpectedReply,
        error.OutOfMemory,
        => .may_have_executed,
    };
}

/// The details of one error, for logs and tests, filled in when the caller
/// passes a pointer in the options of a call. Nothing is allocated: the
/// texts live in fixed buffers of the struct, and the slices that its
/// methods return point there. Every call starts it afresh, so a
/// `Diagnostics` used again holds nothing of the error before.
///
/// The message is the server's error as the server sent it, its code
/// first, or a text of the client. The client's texts hold no arguments,
/// no values and no passwords. A server's text may quote arguments (`ERR
/// unknown command 'FOO', with args beginning with: …`), so log it where
/// such values may go.
pub const Diagnostics = struct {
    /// Where the error happened. `tls` is for a later release with TLS,
    /// which may add other values too, so a `switch` over it needs `else`.
    pub const Phase = enum(u8) { checkout, connect, tls, handshake, send, wait, receive, _ };

    /// The refusal of one command of a transaction as the server queued
    /// it: its code, such as "NOPERM", and its text, as the server sent
    /// them.
    pub const Refused = struct {
        code: []const u8,
        message: []const u8,
    };

    phase: ?Phase = null,
    /// The error of std underneath, for logs, not for logic.
    cause: ?anyerror = null,
    /// For a pipeline or a transaction: the index of the command the error
    /// is about.
    command: ?usize = null,
    /// For a pipeline or a transaction that broke off: how many replies
    /// came before it did. Of a pipeline, those commands ran, and the rest
    /// may have. Of a transaction, they are the +OK of MULTI and the
    /// +QUEUED of each command queued: whether EXEC ran the commands is
    /// unknown.
    answered: ?usize = null,
    code_buffer: [32]u8 = undefined,
    code_len: u8 = 0,
    buffer: [512]u8 = undefined,
    len: u16 = 0,
    refused_code_buffer: [32]u8 = undefined,
    refused_code_len: u8 = 0,
    refused_buffer: [512]u8 = undefined,
    refused_len: u16 = 0,
    has_refused: bool = false,

    /// The server's error as it sent it, the code first, or the client's
    /// text: UTF-8, at most 512 bytes.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.buffer[0..d.len];
    }

    /// The first word of the server's error, such as "WRONGTYPE", at most
    /// 32 bytes; empty when the client, not the server, gave the error.
    pub fn code(d: *const Diagnostics) []const u8 {
        return d.code_buffer[0..d.code_len];
    }

    /// Whether the server's error has the code `name`: `code() == name`,
    /// which slices in Zig cannot write.
    pub fn isCode(d: *const Diagnostics, name: []const u8) bool {
        return d.code_len > 0 and std.mem.eql(u8, d.code(), name);
    }

    /// For a `ServerError` of a transaction that the server dropped with
    /// `EXECABORT` because it refused a command as it queued it: that
    /// command's own code and text, while `command` holds its index. Null
    /// when `EXEC` failed a check of its own (`READONLY`, `OOM`), and for
    /// every other error.
    pub fn refused(d: *const Diagnostics) ?Refused {
        if (!d.has_refused) return null;
        return .{
            .code = d.refused_code_buffer[0..d.refused_code_len],
            .message = d.refused_buffer[0..d.refused_len],
        };
    }

    /// Records a text of the client, which has no code, with the phase and
    /// the cause; the other fields stay. A text longer than the buffer is
    /// cut before the first character that does not fit whole, and a byte
    /// that is not UTF-8 becomes '?'.
    pub fn set(d: *Diagnostics, phase: ?Phase, cause: ?anyerror, comptime fmt: []const u8, args: anytype) void {
        d.phase = phase;
        d.cause = cause;
        var w: std.Io.Writer = .fixed(&d.buffer);
        w.print(fmt, args) catch {};
        d.len = @intCast(wholeUtf8(d.buffer[0..w.end]));
        d.code_len = 0;
    }

    /// Records an error of the server, `text` as it sent it, with the phase
    /// and no cause; its first word becomes the code. The other fields
    /// stay.
    pub fn setServer(d: *Diagnostics, phase: ?Phase, text: []const u8) void {
        d.phase = phase;
        d.cause = null;
        d.len = @intCast(copyText(&d.buffer, text));
        d.code_len = @intCast(copyText(&d.code_buffer, firstWord(text)));
    }

    /// Records the refusal of a command of a transaction, `text` as the
    /// server sent it, for `refused`; the caller sets `command`.
    pub fn setRefused(d: *Diagnostics, text: []const u8) void {
        d.refused_len = @intCast(copyText(&d.refused_buffer, text));
        d.refused_code_len = @intCast(copyText(&d.refused_code_buffer, firstWord(text)));
        d.has_refused = true;
    }
};

/// The code of a server's error: its text up to the first space.
fn firstWord(text: []const u8) []const u8 {
    return text[0 .. std.mem.findScalar(u8, text, ' ') orelse text.len];
}

/// Copies as much of `text` as fits `buffer`, made UTF-8 by `wholeUtf8`,
/// and returns how many bytes it holds: at most `buffer.len`.
fn copyText(buffer: []u8, text: []const u8) usize {
    const n = @min(text.len, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    return wholeUtf8(buffer[0..n]);
}

/// Makes `bytes` UTF-8 in place: a byte that neither starts nor continues
/// a character becomes '?'. Returns the length of the longest prefix that
/// ends on a whole character, so that a text cut short at the end of a
/// buffer drops the character it cut.
fn wholeUtf8(bytes: []u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            bytes[i] = '?';
            i += 1;
            continue;
        };
        if (bytes.len - i < len) {
            // Only continuation bytes up to the end: a character cut short.
            for (bytes[i + 1 ..]) |byte| {
                if (byte & 0xC0 != 0x80) break;
            } else return i;
            bytes[i] = '?';
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
            i += len;
        } else |_| {
            bytes[i] = '?';
            i += 1;
        }
    }
    return i;
}
