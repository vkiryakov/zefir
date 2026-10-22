//! The URL of `redis.Client.Options.url`:
//!
//! `redis://[[user]:password@]host[:port][/db]`
//!
//! - The scheme is `redis://`, in any case. `rediss://`, TLS, is
//!   `error.Unsupported`: v0.1 belongs on a trusted network. So are UNIX
//!   sockets (`unix://`, `redis+unix://`) and every other scheme,
//!   `valkey://` among them: Valkey takes `redis://`.
//! - The user and the password are percent-encoded: `@` is `%40`, `:` is
//!   `%3A`, `/` is `%2F`, `?` is `%3F` and `%` is `%25`, so
//!   `app:s3cr%40t@cache` is the user `app` with the password `s3cr@t`.
//!   The first `:` ends the user. Without a user, as in `:secret@cache`,
//!   the password is that of the user `default`; a user without a
//!   password, as in `app@cache`, takes it from `Options.password`, a
//!   secret kept out of the URL.
//! - One host: a name, an IPv4 address or an IPv6 address in brackets,
//!   `[::1]`. A name is looked up again for every new connection. The port
//!   is 6379 unless the URL gives one.
//! - The path is the number of the database, 0 unless the URL gives one;
//!   whether the server has it, `SELECT` tells as a connection opens.
//! - Options after `?` are `error.Unsupported`: they live in
//!   `redis.Client.Options`, so that a URL copied from another client
//!   never quietly means something else.
//!
//! No text of an error shows the user or the password.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("errors.zig").Diagnostics;

/// A URL, read. Its strings are percent-decoded copies.
pub const Url = struct {
    /// A name, in lower case, or an IP address; an IPv6 one without its
    /// brackets.
    host: []const u8,
    port: u16 = default_port,
    /// The user; null when the URL names none, and HELLO's AUTH, if any,
    /// is for the user `default`.
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// The number of the database, which `SELECT` picks.
    database: u32 = 0,
    /// What the strings point into, from the allocator of `parse`.
    bytes: []u8 = &.{},

    pub const Error = error{
        /// The URL cannot be read.
        InvalidArgument,
        /// The URL asks for what v0.1 cannot do.
        Unsupported,
        OutOfMemory,
    };

    pub const default_port = 6379;
    /// The highest number of a database: a server keeps its count in an
    /// int.
    pub const max_database = std.math.maxInt(i32);

    /// Reads `text`, whose strings it copies into `gpa`: free them with
    /// `deinit`. Why it refused `text` goes to `diagnostics`, which never
    /// shows the user and the password.
    pub fn parse(gpa: Allocator, text: []const u8, diagnostics: ?*Diagnostics) Error!Url {
        const d = diagnostics;
        const separator = std.mem.find(u8, text, "://") orelse
            return fail(d, error.InvalidArgument, "a URL starts with redis://, as in redis://host:6379", .{});
        try checkScheme(text[0..separator], d);
        const rest = text[separator + 3 ..];
        // The first '/' or '?' ends the user and the host; the last '@'
        // before it ends the user.
        const end = std.mem.findAny(u8, rest, "/?") orelse rest.len;
        const authority = rest[0..end];
        const tail = rest[end..];
        // A '@' after it: a '/' or a '?' in the password, unescaped.
        if (std.mem.findScalar(u8, tail, '@') != null) return fail(d, error.InvalidArgument, percent_hint, .{});
        if (std.mem.findScalar(u8, tail, '?') != null) return fail(d, error.Unsupported, "v0.1 takes no options in the URL; set them in redis.Client.Options", .{});
        const at = std.mem.findScalarLast(u8, authority, '@');

        // Decoding never makes a part longer, and the parts do not overlap.
        const bytes = try gpa.alloc(u8, text.len);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            gpa.free(bytes);
        }
        var out: Out = .{ .bytes = bytes };
        var url: Url = .{ .host = "", .bytes = bytes };
        try url.parseHost(&out, if (at) |a| authority[a + 1 ..] else authority, d);
        if (at) |a| try url.parseUser(&out, authority[0..a], d);
        // `tail` is empty or starts with the '/' of the path.
        if (tail.len > 1) url.database = parseDatabase(tail[1..]) orelse
            return fail(d, error.InvalidArgument, "the database of the URL is a number from 0 to 2147483647, as in redis://host:6379/3", .{});
        return url;
    }

    /// Wipes the strings, the user and the password among them, and frees
    /// them.
    pub fn deinit(url: *Url, gpa: Allocator) void {
        std.crypto.secureZero(u8, url.bytes);
        gpa.free(url.bytes);
        url.* = undefined;
    }

    fn parseHost(url: *Url, out: *Out, host_port: []const u8, d: ?*Diagnostics) Error!void {
        var port: ?[]const u8 = null;
        if (host_port.len > 0 and host_port[0] == '[') {
            const close = std.mem.findScalar(u8, host_port, ']') orelse
                return fail(d, error.InvalidArgument, "the IPv6 address of the URL has no ']': redis://[::1]:6379", .{});
            // A zone, as in [fe80::1%25en0], is percent-encoded.
            const literal = out.decode(host_port[1..close]) catch "";
            if (!isIp6(literal)) return fail(d, error.InvalidArgument, "'{s}' is not an IPv6 address", .{host_port[0 .. close + 1]});
            url.host = literal;
            const after = host_port[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return fail(d, error.InvalidArgument, "after the IPv6 address of the URL comes ':' and the port: redis://[::1]:6379", .{});
                port = after[1..];
            }
        } else {
            const colon = std.mem.findScalar(u8, host_port, ':');
            if (colon) |c| if (std.mem.findScalarLast(u8, host_port, ':') != c) {
                return fail(d, error.InvalidArgument, "an IPv6 address in a URL goes in brackets: redis://[::1]:6379", .{});
            };
            const name = host_port[0 .. colon orelse host_port.len];
            if (name.len == 0) return fail(d, error.InvalidArgument, "the URL names no host: redis://host:6379", .{});
            // Host names are not case-sensitive.
            const lower = out.lower(name);
            Io.net.HostName.validate(lower) catch return fail(d, error.InvalidArgument, "'{s}' is not a host name or an IP address", .{name});
            url.host = lower;
            if (colon) |c| port = host_port[c + 1 ..];
        }
        if (port) |text| url.port = parsePort(text) orelse return fail(d, error.InvalidArgument, "the port of the URL is a number from 1 to 65535", .{});
    }

    fn parseUser(url: *Url, out: *Out, info: []const u8, d: ?*Diagnostics) Error!void {
        if (info.len == 0) return fail(d, error.InvalidArgument, "the URL has an empty user before '@': write redis://user:password@host, or leave the user out", .{});
        // RFC 3986: unreserved characters, percent-encoded bytes,
        // sub-delimiters and ':'.
        for (info) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '%', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':' => {},
            else => return fail(d, error.InvalidArgument, percent_hint, .{}),
        };
        const colon = std.mem.findScalar(u8, info, ':');
        const user = out.decode(info[0 .. colon orelse info.len]) catch return fail(d, error.InvalidArgument, percent_hint, .{});
        if (user.len > 0) url.username = user;
        if (colon) |c| url.password = out.decode(info[c + 1 ..]) catch return fail(d, error.InvalidArgument, percent_hint, .{});
    }
};

const percent_hint = "the user and the password in a URL are percent-encoded: write '@' as %40, ':' as %3A, '/' as %2F, '?' as %3F and '%' as %25";
const no_tls = "TLS is not supported in v0.1; use a trusted network";

/// `error.Unsupported` for every scheme but `redis`, with what to write
/// instead. The scheme is not shown: it is the caller's text.
fn checkScheme(scheme: []const u8, d: ?*Diagnostics) Url.Error!void {
    const is = std.ascii.eqlIgnoreCase;
    if (is(scheme, "redis")) return;
    if (is(scheme, "rediss") or is(scheme, "valkeys")) return fail(d, error.Unsupported, no_tls, .{});
    if (is(scheme, "unix") or is(scheme, "redis+unix") or is(scheme, "rediss+unix")) {
        return fail(d, error.Unsupported, "a UNIX socket: v0.1 connects over TCP; give redis://host:port", .{});
    }
    if (is(scheme, "valkey")) return fail(d, error.Unsupported, "valkey:// is not a scheme of v0.1: write redis://, which Valkey takes too", .{});
    return fail(d, error.Unsupported, "v0.1 takes a URL of the scheme redis://, as in redis://host:6379", .{});
}

/// Where the decoded strings go, one after another.
const Out = struct {
    bytes: []u8,
    len: usize = 0,

    /// `raw` with each %XX turned into its byte.
    fn decode(out: *Out, raw: []const u8) error{BadPercent}![]const u8 {
        const start = out.len;
        var i: usize = 0;
        while (i < raw.len) {
            var byte = raw[i];
            i += 1;
            if (byte == '%') {
                if (raw.len - i < 2) return error.BadPercent;
                const high = std.fmt.charToDigit(raw[i], 16) catch return error.BadPercent;
                const low = std.fmt.charToDigit(raw[i + 1], 16) catch return error.BadPercent;
                byte = high << 4 | low;
                i += 2;
            }
            out.bytes[out.len] = byte;
            out.len += 1;
        }
        return out.bytes[start..out.len];
    }

    fn lower(out: *Out, raw: []const u8) []const u8 {
        const copy = std.ascii.lowerString(out.bytes[out.len..][0..raw.len], raw);
        out.len += raw.len;
        return copy;
    }
};

fn isIp6(text: []const u8) bool {
    // An address with a zone takes far less; the parser counts in u8.
    if (text.len > 64) return false;
    return Io.net.Ip6Address.Unresolved.parse(text) == .success;
}

fn parsePort(text: []const u8) ?u16 {
    const port = parseDecimal(text, 5) orelse return null;
    if (port == 0 or port > std.math.maxInt(u16)) return null;
    return @intCast(port);
}

fn parseDatabase(text: []const u8) ?u32 {
    const n = parseDecimal(text, 10) orelse return null;
    if (n > Url.max_database) return null;
    return @intCast(n);
}

/// Decimal digits only, 1 to `max_digits` of them.
fn parseDecimal(text: []const u8, comptime max_digits: usize) ?u64 {
    if (text.len == 0 or text.len > max_digits) return null;
    var n: u64 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn fail(d: ?*Diagnostics, err: Url.Error, comptime fmt: []const u8, args: anytype) Url.Error {
    if (d) |x| x.set(null, null, fmt, args);
    return err;
}
