//! The errors of the client and of the collection API, and what the
//! client or the server said about one.
//!
//! - `Error` — the closed set of 16 names that the functions of
//!   `mongo.Client`, `mongo.Cursor` and the collection API return.
//! - `outcome` — whether the server may have run the operation:
//!   `.not_sent` is safe to retry, `.may_have_executed` only for an
//!   operation that may run twice. Safe is not the same as worth it: of
//!   the `.not_sent` errors, `Unavailable` and `PoolExhausted` may go
//!   through later, `DeadlineExceeded` and `Cancelled` only with a new
//!   context, and `InvalidArgument`, `Unsupported`, `Closed` and
//!   `AuthenticationFailed` fail the same way again. Nothing in zefir
//!   retries by itself.
//! - `Diagnostics` — the details of one error, for logs: where it
//!   happened, the error of the library underneath, the server's error,
//!   and the server's errmsg or the driver's text.
//! - `ServerError` and `Label` — the code, codeName and errorLabels of a
//!   reply with `ok: 0`.
//!
//! ```zig
//! var diagnostics: mongo.Diagnostics = .{};
//! const reply = client.runCommand(io, .of(ctx), command, .{ .allocator = arena, .diagnostics = &diagnostics }) catch |err| {
//!     log.warn("{t}: {s}", .{ err, diagnostics.message() });
//!     // Nothing ran, and the server may be back, or a connection free,
//!     // later.
//!     if (err == error.Unavailable or err == error.PoolExhausted) return retryLater();
//!     return err;
//! };
//! ```

const std = @import("std");
const bson = @import("bson.zig");

/// What can go wrong in a call. Each name says whether the server may have
/// run the operation; `outcome` tells it in code.
pub const Error = error{
    /// The request breaks a rule of the client or of the collection API:
    /// a bad database name, a field that only the driver writes, an empty
    /// write, an item that no message can hold, a bad URI. Not sent.
    InvalidArgument,
    /// The client does not do what the call needs: an option of the
    /// connection string that it lacks, TLS among them, a server other than
    /// a standalone mongod of 7.0 or later, SCRAM-SHA-256 with a password
    /// that is not ASCII. Not sent.
    Unsupported,
    /// The client or the cursor was closed before the call. Not sent.
    Closed,
    /// No connection: DNS, TCP or hello failed, the pool is paused after a
    /// clear, or `connect` has not succeeded. Not sent.
    Unavailable,
    /// The server refused the credentials. Not sent.
    AuthenticationFailed,
    /// The deadline or the checkout budget ran out in the pool's queue.
    /// Not sent.
    PoolExhausted,
    /// The deadline left less than 1 ms, or less than a round trip, before
    /// sending, or it passed while connecting. Not sent.
    DeadlineExceeded,
    /// The token was canceled before the call or before sending, or the
    /// task was canceled before sending. Not sent.
    Cancelled,
    /// The connection broke after the command started to go out, or
    /// `close` of the client cut the exchange. May have executed.
    ConnectionLost,
    /// The deadline passed after the command went out, or the server
    /// answered MaxTimeMSExpired (code 50). May have executed.
    Timeout,
    /// The task was canceled while the command was out, or the token was
    /// canceled while it was. May have executed.
    Interrupted,
    /// A write of several batches stopped after a batch that the server
    /// had answered; `Diagnostics.reason` says why. May have executed.
    IncompleteWrite,
    /// The reply broke OP_MSG, or lacked a field it must hold. May have
    /// executed.
    ProtocolViolation,
    /// The server answered `ok: 0`; its error is in `Diagnostics.server`.
    /// May have executed.
    CommandFailed,
    /// Only from the collection API: the write ran to its end, but the
    /// server refused items (writeErrors) or the write concern
    /// (writeConcernError). May have executed.
    WriteFailed,
    /// Always may have executed: the caller cannot tell where memory ran
    /// out.
    OutOfMemory,
};

/// Whether an operation that failed may have run on the server.
pub const Outcome = enum {
    /// Nothing reached the server: the call is safe to make again. It
    /// goes through only once what failed it has changed: the server is
    /// back or a connection free (`Unavailable`, `PoolExhausted`), or the
    /// context is new (`DeadlineExceeded`, `Cancelled`). The rest fail the
    /// same way again.
    not_sent,
    /// The server may have run it, wholly or in part: make it again only
    /// if running it twice is safe.
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
        error.IncompleteWrite,
        error.ProtocolViolation,
        error.CommandFailed,
        error.WriteFailed,
        error.OutOfMemory,
        => .may_have_executed,
    };
}

/// The details of one error, for logs and tests, filled in when the
/// caller passes a pointer in the options of a call. Nothing is allocated:
/// the text lives in a fixed buffer. Every call starts it afresh, so a
/// `Diagnostics` used again holds nothing of the error before.
///
/// The message is the server's errmsg, as the server wrote it, or a text
/// of the driver. The driver's texts hold no bodies of commands, no values
/// of documents and no secrets. An errmsg may quote values of a document
/// (code 11000: `dup key: { email: … }`), so log it where such values may
/// go.
pub const Diagnostics = struct {
    /// Where the error happened. `tls` is for a later release with TLS,
    /// which may add other values too, so a `switch` over it needs `else`.
    pub const Phase = enum(u8) { checkout, connect, tls, handshake, authenticate, send, wait, receive, _ };

    phase: ?Phase = null,
    /// The error of std or of a library underneath, for logs, not for logic.
    cause: ?anyerror = null,
    /// The server's error, when the server answered: `CommandFailed`,
    /// `WriteFailed`, `Timeout` by code 50. The client may also give an
    /// error of its own errorLabels here, with code 0, as the overload
    /// labels that CMAP gives a network error while a connection opens.
    server: ?ServerError = null,
    /// For a write: the index of the first item of the batch where the
    /// write stopped.
    batch_offset: ?usize = null,
    /// For `IncompleteWrite`: the error the write stopped at. Its class
    /// says whether that batch reached the server.
    reason: ?Error = null,
    buffer: [512]u8 = undefined,
    len: u16 = 0,

    /// The server's errmsg or the driver's text: UTF-8, at most 512 bytes.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.buffer[0..d.len];
    }

    /// Records the phase, the cause and a formatted message; the other
    /// fields stay. A message longer than the buffer is cut before the
    /// first character that does not fit whole, and a byte that is not
    /// UTF-8 becomes '?'.
    pub fn set(d: *Diagnostics, phase: ?Phase, cause: ?anyerror, comptime fmt: []const u8, args: anytype) void {
        d.phase = phase;
        d.cause = cause;
        var w: std.Io.Writer = .fixed(&d.buffer);
        w.print(fmt, args) catch {};
        d.len = @intCast(wholeUtf8(d.buffer[0..w.end]));
    }

    /// Records the error of `reply`, a reply with `ok: 0`: its code,
    /// codeName and errorLabels in `server`, and its errmsg as the message.
    pub fn setServer(d: *Diagnostics, phase: ?Phase, reply: bson.RawDocument) void {
        const errmsg = if (reply.get("errmsg") catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        d.set(phase, null, "{s}", .{errmsg});
        d.server = ServerError.fromReply(reply);
    }
};

/// The error of a reply with `ok: 0`, without its errmsg, which goes to
/// `Diagnostics.message`. Compare codes by number, not by name.
pub const ServerError = struct {
    /// The code, such as 11000 (DuplicateKey) or 50 (MaxTimeMSExpired);
    /// 0 when the reply has none.
    code: i32,
    code_name: Name = .{},
    labels: std.EnumSet(Label) = .empty,
    /// How many errorLabels `Label` does not know; the reply holds them.
    unknown_labels: u8 = 0,

    /// The codeName, at most 64 bytes, cut by whole UTF-8 characters.
    pub const Name = struct {
        buffer: [64]u8 = undefined,
        len: u8 = 0,

        pub fn init(text: []const u8) Name {
            var name: Name = .{};
            const n = @min(text.len, name.buffer.len);
            @memcpy(name.buffer[0..n], text[0..n]);
            name.len = @intCast(wholeUtf8(name.buffer[0..n]));
            return name;
        }

        pub fn slice(name: *const Name) []const u8 {
            return name.buffer[0..name.len];
        }
    };

    /// Reads `code`, `codeName` and `errorLabels` of `reply`; what is
    /// missing, or of another type, stays empty.
    pub fn fromReply(reply: bson.RawDocument) ServerError {
        var server: ServerError = .{ .code = 0 };
        var it = reply.iterator();
        while (it.next() catch null) |element| {
            if (std.mem.eql(u8, element.key, "code")) {
                const code = element.value.asI64() catch continue;
                server.code = std.math.cast(i32, code) orelse 0;
            } else if (std.mem.eql(u8, element.key, "codeName")) {
                if (element.value == .string) server.code_name = .init(element.value.string);
            } else if (std.mem.eql(u8, element.key, "errorLabels")) {
                if (element.value != .array) continue;
                var labels = element.value.array.iterator();
                while (labels.next() catch null) |label| {
                    const known = if (label.value == .string) Label.fromName(label.value.string) else null;
                    if (known) |l| server.labels.insert(l) else server.unknown_labels +|= 1;
                }
            }
        }
        return server;
    }
};

/// The errorLabels that zefir-mongo knows, the overload labels of 2026
/// among them.
pub const Label = enum {
    retryable_write_error,
    transient_transaction_error,
    unknown_transaction_commit_result,
    no_writes_performed,
    resumable_change_stream_error,
    system_overloaded_error,
    retryable_error,

    /// As the server writes it: "RetryableWriteError".
    pub fn name(label: Label) []const u8 {
        return names[@backingInt(label)];
    }

    /// The label the server writes so, or null.
    pub fn fromName(text: []const u8) ?Label {
        for (names, 0..) |spelled, i| {
            if (std.mem.eql(u8, spelled, text)) return @fromBackingInt(@intCast(i));
        }
        return null;
    }

    const names = [_][]const u8{
        "RetryableWriteError",
        "TransientTransactionError",
        "UnknownTransactionCommitResult",
        "NoWritesPerformed",
        "ResumableChangeStreamError",
        "SystemOverloadedError",
        "RetryableError",
    };
};

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
