//! The errors of odm, and what the driver, the server or odm said about
//! one.
//!
//! - `DriverError` — the 17 names that a driver returns (`odm.Client`,
//!   `odm.RawCursor`).
//! - `Error` — what the calls of odm return: `DriverError` and 11 names of
//!   odm's own.
//! - `outcome` — whether the server may have run the operation:
//!   `.not_sent` is safe to make again, `.may_have_executed` only for an
//!   operation that may run twice. Nothing in odm makes a call again by
//!   itself.
//! - `Diagnostics` — the details of one error, for logs: the server's
//!   code, the item of a write that it refused, the rule that a document
//!   broke, the error of the decoder, the path of the field, and a text.
//!
//! ```zig
//! _ = users.insertOne(io, ctx, user) catch |err| {
//!     const d = session.diagnostics();
//!     log.warn("insert: {t}: {s} at '{s}'", .{ err, d.message(), d.path() });
//!     if (odm.outcome(err) == .not_sent) return retryLater();
//!     return err;
//! };
//! ```

const std = @import("std");

/// What a driver returns. Each name says whether the server may have run
/// the operation; `outcome` tells it in code.
pub const DriverError = error{
    /// The request breaks a rule of odm or of the driver: an empty
    /// `insertMany`, a bad name or id, an empty `odm.Update(T)`, two `with`
    /// whose paths conflict. Not sent.
    InvalidArgument,
    /// The driver lacks the capability that the call needs, or cannot do a
    /// setting, such as `minPoolSize=5` or `tls=true`. Not sent.
    Unsupported,
    /// The client is closed, or its generation was closed by force: the
    /// drain ran out, or the registry shut down. Not sent.
    Closed,
    /// No connection to the server: it is down, the pool is paused (also
    /// after the server refused the login of a new connection), or the
    /// client has not connected. Not sent.
    Unavailable,
    /// The server refused the login; for the calls of an old generation
    /// also after a new password of the same user. Not sent.
    AuthenticationFailed,
    /// No connection of the pool became free in time. Not sent.
    PoolExhausted,
    /// Less than 1 ms was left of the deadline before sending, or the
    /// deadline passed while the call waited for a connection's turn or
    /// for a tenant's queue. Not sent.
    DeadlineExceeded,
    /// The token or the task was canceled before sending. Not sent.
    Cancelled,
    /// The link broke after sending began, or a forced close cut the call.
    /// May have executed.
    ConnectionLost,
    /// The deadline passed after sending, or the server answered
    /// MaxTimeMSExpired. May have executed.
    Timeout,
    /// The call was canceled while it was on the server. May have
    /// executed.
    Interrupted,
    /// A write of several batches stopped in the middle. May have
    /// executed.
    IncompleteWrite,
    /// The reply broke the protocol. May have executed.
    ProtocolViolation,
    /// The server answered `ok: 0`; its code is in `Diagnostics.code`, such
    /// as 13 for a login without the rights. May have executed.
    CommandFailed,
    /// The server refused an item of a write for a reason other than a
    /// unique index. May have executed.
    WriteFailed,
    /// A unique index refused a document (server code 11000, 11001 or
    /// 12582); `Diagnostics.index` names it, and the documents before it
    /// went in. May have executed.
    DuplicateKey,
    /// Always may have executed: the caller cannot tell where memory ran
    /// out.
    OutOfMemory,
};

/// What the calls of odm return: the errors of the driver and these.
pub const Error = DriverError || error{
    /// A document broke the `field_rules` of its model; the rule and the
    /// path are in `Diagnostics`. Not sent.
    ValidationFailed,
    /// A value did not become BSON: a string that is not UTF-8, documents
    /// nested deeper than 100. Not sent.
    EncodeFailed,
    /// A document of the server is not valid BSON. The request reached the
    /// server: may have executed.
    InvalidBson,
    /// A document of the server does not fit the model; the path and the
    /// cause are in `Diagnostics`. The request reached the server: may have
    /// executed.
    DecodeFailed,
    /// No such tenant, or its id cannot be one. Not sent.
    TenantNotFound,
    /// No connection of that id. Not sent.
    ConnectionNotFound,
    /// A connection of that id is there already. Not sent.
    ConnectionExists,
    /// Tenants are bound to the connection: remove them first. Not sent.
    ConnectionInUse,
    /// A provisioning of a tenant with a version older than the tenant's;
    /// the current version is in the text of the diagnostics. Nothing
    /// changed. Not sent.
    StaleVersion,
    /// A provisioning with the tenant's version and other settings, or a
    /// new connection with a known id and other credentials: change those
    /// with `replaceConnection`. Not sent.
    ProvisioningConflict,
    /// The registry is shutting down or has shut down. Not sent.
    ShuttingDown,
};

/// What `Registry.shutdown` returns when the deadline came before the
/// leases did; the generations left were closed by force.
pub const ShutdownError = error{ShutdownTimeout};

/// Whether an operation that failed may have run on the server.
pub const Outcome = enum {
    /// Nothing reached the server: the call is safe to make again. It
    /// goes through only once what failed it has changed: the server is
    /// back or a connection free (`Unavailable`, `PoolExhausted`), the
    /// context is new (`DeadlineExceeded`, `Cancelled`), the tenant or the
    /// connection is there. The rest fail the same way again.
    not_sent,
    /// The server may have run it, wholly or in part: make it again only
    /// if running it twice is safe.
    may_have_executed,
};

/// The class of `err`, by table 5.11 of the design. The switch is the
/// table: a new name of `Error` stops the build until it has a class.
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
        error.ValidationFailed,
        error.EncodeFailed,
        error.TenantNotFound,
        error.ConnectionNotFound,
        error.ConnectionExists,
        error.ConnectionInUse,
        error.StaleVersion,
        error.ProvisioningConflict,
        error.ShuttingDown,
        => .not_sent,
        error.ConnectionLost,
        error.Timeout,
        error.Interrupted,
        error.IncompleteWrite,
        error.ProtocolViolation,
        error.CommandFailed,
        error.WriteFailed,
        error.DuplicateKey,
        error.InvalidBson,
        error.DecodeFailed,
        error.OutOfMemory,
        => .may_have_executed,
    };
}

/// The details of one error, for logs and tests. Nothing is allocated: the
/// text and the path live in buffers inside, so a copy keeps its own.
///
/// The text is the driver's or the server's errmsg, as the server wrote
/// it, or one of odm. No text holds a password or a connection string. An
/// errmsg may quote values of a document (code 11000:
/// `dup key: { email: … }`), so log it where such values may go.
pub const Diagnostics = struct {
    /// The server's code: 11000, 11001 or 12582 for `DuplicateKey`, 13
    /// Unauthorized, 59 CommandNotFound.
    code: ?i32 = null,
    /// The item of a write that the server refused, or the document of an
    /// `insertMany` that broke its rules or did not become BSON: its index
    /// in the list of the call.
    index: ?usize = null,
    /// `ValidationFailed`: the rule, by the code and the message of
    /// zefir-validator.
    violation: ?Violation = null,
    /// `DecodeFailed`: the error of the decoder, such as `MissingField`,
    /// `WrongType` or `Overflow`.
    cause: ?anyerror = null,
    text_buffer: [512]u8 = undefined,
    text_len: u16 = 0,
    path_buffer: [256]u8 = undefined,
    path_len: u16 = 0,

    /// A rule of zefir-validator that a document broke.
    pub const Violation = struct { code: []const u8, message: []const u8 };

    /// The text of the driver, the server's errmsg, or a text of odm:
    /// UTF-8, at most 512 bytes.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.text_buffer[0..d.text_len];
    }

    /// The path of the field: the names of zefir-validator for a
    /// violation, the keys of BSON for a document that did not decode;
    /// UTF-8, at most 256 bytes, of which a longer path keeps the end
    /// behind "…".
    pub fn path(d: *const Diagnostics) []const u8 {
        return d.path_buffer[0..d.path_len];
    }

    /// For drivers: records the code, the index and a formatted text; the
    /// other fields stay. A text longer than 512 bytes is cut before the
    /// first character that does not fit whole, and a byte that is not
    /// UTF-8 becomes '?'.
    pub fn set(d: *Diagnostics, code: ?i32, index: ?usize, comptime fmt: []const u8, args: anytype) void {
        d.code = code;
        d.index = index;
        var w: std.Io.Writer = .fixed(&d.text_buffer);
        w.print(fmt, args) catch {};
        d.text_len = @intCast(wholeUtf8(d.text_buffer[0..w.end]));
    }

    /// Records the path of the field; the other fields stay. A path over
    /// 256 bytes keeps its end behind "…", whole fields when the end holds
    /// a dot, as `bson.DecodeDiagnostics` does: "….items.0.name".
    pub fn setPath(d: *Diagnostics, full: []const u8) void {
        if (full.len <= d.path_buffer.len) {
            @memcpy(d.path_buffer[0..full.len], full);
            d.path_len = @intCast(wholeUtf8(d.path_buffer[0..full.len]));
            return;
        }
        const ellipsis = "…";
        var start = full.len - (d.path_buffer.len - ellipsis.len);
        // Start at a character, past the rest of one that the cut split.
        while (start < full.len and full[start] & 0xC0 == 0x80) start += 1;
        if (std.mem.findScalarPos(u8, full, start, '.')) |dot| start = dot;
        const end = full[start..];
        @memcpy(d.path_buffer[0..ellipsis.len], ellipsis);
        @memcpy(d.path_buffer[ellipsis.len..][0..end.len], end);
        d.path_len = @intCast(ellipsis.len + wholeUtf8(d.path_buffer[ellipsis.len..][0..end.len]));
    }
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
