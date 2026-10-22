//! The options of `redis.Client.init`. Only `url` has no default:
//!
//! ```zig
//! var client: redis.Client = try .init(gpa, io, .{
//!     .url = "redis://app@cache.internal:6379/0",
//!     .password = config.redis.password.expose(), // a confy.Secret
//!     .client_name = "orders",
//! });
//! ```
//!
//! `init` checks them and keeps its own copy, so the strings may be freed
//! once the client is created:
//!
//! - `max_connections` is 1 or more;
//! - every duration is 1 ms or more and at most `maxInt(i64)` ms, and
//!   `timeout` may be null;
//! - `max_reply_bytes` is 64 KiB or more;
//! - the user, the password and `client_name` are at most 16 384 bytes,
//!   the most a server reads of an argument before authentication, and
//!   `client_name` holds the bytes 0x21 to 0x7E only, printable ASCII
//!   without spaces.

const std = @import("std");
const Duration = std.Io.Duration;
const Diagnostics = @import("errors.zig").Diagnostics;

/// The server: `redis.Client.Url` lists what it may hold.
url: []const u8,
/// The password of the user of `url`, or of the user `default`, when the
/// URL does not hold it: a secret kept out of the URL.
password: ?[]const u8 = null,
/// The name of the client's connections in `CLIENT LIST`, sent in
/// `HELLO … SETNAME`; null: none.
client_name: ?[]const u8 = null,
/// How many connections the pool keeps at most; subscribers come on top.
max_connections: u32 = 32,
/// The deadline of a call whose context has none; for a blocking command,
/// the margin beyond its own timeout. Null: no deadline of its own.
timeout: ?Duration = .fromSeconds(5),
/// How long DNS, TCP and the handshake of a new connection may take; the
/// deadline of the call may cut it shorter.
connect_timeout: Duration = .fromSeconds(5),
/// The deadline of `start`, for zefir.App: the first connection, its
/// handshake included.
start_timeout: Duration = .fromSeconds(10),
/// How long `close` lets the calls in flight finish before it cuts them.
close_timeout: Duration = .fromSeconds(5),
/// The largest reply, in bytes on the wire; a larger one is
/// `error.ReplyTooLarge`. A reply read into `redis.Value` may take several
/// times this in memory: a null is 3 bytes on the wire and a whole
/// `Value` in the arena.
max_reply_bytes: usize = 64 * 1024 * 1024,
/// Why `init` refused the options; it never shows the password.
diagnostics: ?*Diagnostics = null,
