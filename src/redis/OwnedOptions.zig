//! The client's own copy of its options: checked, the URL read, its
//! strings, the password and the name of the client copied, all of them
//! wiped when freed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Duration = std.Io.Duration;
const Diagnostics = @import("errors.zig").Diagnostics;
const Options = @import("Options.zig");
const Url = @import("url.zig").Url;
const OwnedOptions = @This();

url: Url,
/// The copy of `Options.password`.
password: ?[]u8,
/// The copy of `Options.client_name`.
client_name: ?[]u8,
max_connections: u32,
timeout: ?Duration,
connect_timeout: Duration,
close_timeout: Duration,
max_reply_bytes: usize,

pub const Error = Url.Error;

/// Who HELLO authenticates as.
pub const Credentials = struct {
    /// The user of the URL, or `default`.
    username: []const u8,
    password: []const u8,
};

/// The longest user, password or name of a client: before
/// authentication, a server reads no longer argument.
pub const max_handshake_argument = 16 * 1024;
/// The smallest `max_reply_bytes`.
pub const min_reply_bytes = 64 * 1024;

pub fn init(gpa: Allocator, options: Options) Error!OwnedOptions {
    const d = options.diagnostics;
    if (options.max_connections == 0) return fail(d, "max_connections is 0: the pool needs at least one connection", .{});
    if (options.timeout) |timeout| try checkDuration(timeout, "timeout", ", or null for calls without a deadline of their own", d);
    try checkDuration(options.connect_timeout, "connect_timeout", "", d);
    try checkDuration(options.close_timeout, "close_timeout", "", d);
    if (options.max_reply_bytes < min_reply_bytes) return fail(d, "max_reply_bytes is {d}: it is 65536 (64 KiB) or more", .{options.max_reply_bytes});
    if (options.client_name) |name| try checkClientName(name, d);
    if (options.password) |password| try checkLength(password, "the password", d);

    var url = try Url.parse(gpa, options.url, d);
    errdefer url.deinit(gpa);
    if (url.username) |user| try checkLength(user, "the user", d);
    if (url.password) |password| {
        try checkLength(password, "the password", d);
        if (options.password != null) return fail(d, "the password is given twice, in the URL and in Options.password; keep one", .{});
    } else if (url.username != null and options.password == null) {
        return fail(d, "the URL names a user but no password: add it percent-encoded, redis://user:password@host, or pass Options.password", .{});
    }

    const password = if (options.password) |p| try gpa.dupe(u8, p) else null;
    errdefer if (password) |p| {
        std.crypto.secureZero(u8, p);
        gpa.free(p);
    };
    const client_name = if (options.client_name) |name| try gpa.dupe(u8, name) else null;
    return .{
        .url = url,
        .password = password,
        .client_name = client_name,
        .max_connections = options.max_connections,
        .timeout = options.timeout,
        .connect_timeout = options.connect_timeout,
        .close_timeout = options.close_timeout,
        .max_reply_bytes = options.max_reply_bytes,
    };
}

pub fn deinit(owned: *OwnedOptions, gpa: Allocator) void {
    owned.wipe();
    if (owned.password) |password| gpa.free(password);
    if (owned.client_name) |name| gpa.free(name);
    owned.url.deinit(gpa);
    owned.* = undefined;
}

/// The user and the password of HELLO's AUTH; null when neither the URL
/// nor the options give a password, and HELLO goes without AUTH.
pub fn credentials(owned: *const OwnedOptions) ?Credentials {
    const password = owned.password orelse owned.url.password orelse return null;
    return .{ .username = owned.url.username orelse "default", .password = password };
}

/// Overwrites the copies of the URL and of the password, so that they do
/// not stay in freed memory.
pub fn wipe(owned: *OwnedOptions) void {
    std.crypto.secureZero(u8, owned.url.bytes);
    if (owned.password) |password| std.crypto.secureZero(u8, password);
}

/// 1 ms or more, and at most what the client counts in milliseconds.
fn checkDuration(duration: Duration, comptime name: []const u8, comptime hint: []const u8, d: ?*Diagnostics) Error!void {
    if (duration.nanoseconds < std.time.ns_per_ms) return fail(d, name ++ " is under 1 ms: give it 1 ms or more" ++ hint, .{});
    if (@divTrunc(duration.nanoseconds, std.time.ns_per_ms) > std.math.maxInt(i64)) {
        return fail(d, name ++ " is longer than {d} ms, the most the client counts", .{std.math.maxInt(i64)});
    }
}

fn checkLength(text: []const u8, comptime what: []const u8, d: ?*Diagnostics) Error!void {
    if (text.len > max_handshake_argument) {
        return fail(d, what ++ " is {d} bytes; a server takes {d} at most before authentication", .{ text.len, max_handshake_argument });
    }
}

/// Printable ASCII without spaces, as a server takes in a name.
fn checkClientName(name: []const u8, d: ?*Diagnostics) Error!void {
    if (name.len == 0) return fail(d, "client_name is empty: leave it null for connections without a name", .{});
    try checkLength(name, "client_name", d);
    for (name, 0..) |c, i| if (c < 0x21 or c > 0x7E) {
        return fail(d, "client_name holds a space or a byte outside printable ASCII, at byte {d}: a server takes the bytes 0x21 to 0x7E", .{i});
    };
}

fn fail(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(null, null, fmt, args);
    return error.InvalidArgument;
}
