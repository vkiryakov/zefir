//! The connection string of the driver, by the Connection String and URI
//! Options specifications of MongoDB, and stricter than they are: where
//! they let a driver warn about an option and go on without it, this one
//! refuses an option that would change what it does and that v0.1 cannot
//! do, so that a copied string never quietly means something else.
//!
//! `mongodb://[user[:password]@]host[:port][/[database]][?name=value&...]`
//!
//! - One host: a name, an IPv4 address or an IPv6 address in brackets,
//!   `[::1]`; the port is 27017 unless the string gives one.
//!   `mongodb+srv://`, several hosts and UNIX domain sockets are
//!   `error.Unsupported`.
//! - The user and the password are percent-encoded: `@` is `%40`, `:` is
//!   `%3A`, `/` is `%2F` and `%` is `%25`, so `app:p%40ss@db` is the user
//!   `app` with the password `p@ss`. The password may come from
//!   `Options.password` instead.
//! - The database of the path is where the user is defined, unless
//!   `authSource` names another; without either, it is `admin`.
//!
//! The options, whose names are case-insensitive:
//!
//! | option | meaning |
//! |---|---|
//! | `authSource`, `authMechanism` | where the user is defined; `SCRAM-SHA-256` or `SCRAM-SHA-1`, by default what the server offers |
//! | `appName` | the application's name in the server's logs, 1 to 128 bytes |
//! | `connectTimeoutMS` | DNS, TCP and the handshake of a new connection: 10 000 by default, 0 for no limit |
//! | `serverSelectionTimeoutMS` | how long an operation waits for a connection: 30 000 by default |
//! | `timeoutMS` | the deadline of an operation whose context has none; 0, as no option, is none |
//! | `maxPoolSize`, `maxConnecting`, `maxIdleTimeMS` | the pool: 100 connections at most, 2 being opened at once, idle ones kept for good (0); `maxPoolSize=0` is `error.InvalidArgument` |
//! | `minPoolSize` | 0 only: connections open when operations need them |
//! | `directConnection` | either value: there is one host and nothing else to find |
//! | `tls`, `ssl`, `retryWrites`, `retryReads`, `loadBalanced` | `false` only, the defaults |
//!
//! `error.Unsupported`, with what to do instead: TLS (`tls=true`,
//! `ssl=true` and any `tls…` option), `replicaSet` and the read
//! preferences, retries, the write and read concerns, `socketTimeoutMS`,
//! `waitQueueTimeoutMS`, mechanisms other than SCRAM and their
//! `authMechanismProperties`, SRV and proxies. Skipped with a warning in
//! the log: `compressors`, `zlibCompressionLevel`, `heartbeatFrequencyMS`,
//! `localThresholdMS`, `serverSelectionTryOnce`, `serverMonitoringMode`,
//! `uuidRepresentation` and options the driver does not know.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mongo = @import("root.zig");
const Diagnostics = mongo.Diagnostics;
const log = std.log.scoped(.mongo);

/// A connection string, read. Its strings are percent-decoded copies.
pub const Uri = struct {
    /// A name, in lower case, or an IP address; an IPv6 one without its
    /// brackets.
    host: []const u8,
    port: u16 = default_port,
    /// The user, and the password when the string gives one.
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// The database of the path: "app" of `mongodb://host/app`.
    database: ?[]const u8 = null,
    /// `authSource`: the database the user is defined in.
    auth_source: ?[]const u8 = null,
    /// `authMechanism`; null: the server's `saslSupportedMechs` decides.
    auth_mechanism: ?Mechanism = null,
    /// `appName`.
    app_name: ?[]const u8 = null,
    /// `connectTimeoutMS`; null: no limit.
    connect_timeout: ?Io.Duration = .fromSeconds(10),
    /// `serverSelectionTimeoutMS`.
    server_selection_timeout: Io.Duration = .fromSeconds(30),
    /// `timeoutMS`; null: an operation without a deadline of its own has
    /// none.
    timeout: ?Io.Duration = null,
    /// `maxPoolSize`.
    max_pool_size: u32 = 100,
    /// `maxConnecting`.
    max_connecting: u32 = 2,
    /// `maxIdleTimeMS`; null: an idle connection stays.
    max_idle_time: ?Io.Duration = null,
    /// What the strings point into, from the allocator of `parse`.
    bytes: []u8 = &.{},

    pub const Error = error{
        /// The string cannot be read, or breaks a rule of the
        /// specifications.
        InvalidArgument,
        /// The string asks for what v0.1 cannot do.
        Unsupported,
        OutOfMemory,
    };

    pub const default_port = 27017;
    /// The longest `appName`, by the handshake specification.
    pub const max_app_name = 128;

    pub const Mechanism = enum {
        scram_sha_1,
        scram_sha_256,

        /// As the string and the server write it: "SCRAM-SHA-256".
        pub fn name(m: Mechanism) []const u8 {
            return switch (m) {
                .scram_sha_1 => "SCRAM-SHA-1",
                .scram_sha_256 => "SCRAM-SHA-256",
            };
        }
    };

    /// Reads `text`, whose strings it copies into `gpa`: free them with
    /// `deinit`. Why it refused `text` goes to `diagnostics`, which never
    /// shows the user and the password.
    pub fn parse(gpa: Allocator, text: []const u8, diagnostics: ?*Diagnostics) Error!Uri {
        const d = diagnostics;
        if (std.mem.startsWith(u8, text, "mongodb+srv://")) {
            return fail(d, error.Unsupported, "mongodb+srv:// needs SRV records, which v0.1 does not look up: give the host, mongodb://host:port", .{});
        }
        if (!std.mem.startsWith(u8, text, scheme)) return fail(d, error.InvalidArgument, "a connection string starts with mongodb://", .{});
        const rest = text[scheme.len..];
        // The first '/' ends the user and the hosts; the last '@' before it
        // ends the user.
        const slash = std.mem.findScalar(u8, rest, '/');
        const authority = rest[0 .. slash orelse rest.len];
        const tail = if (slash) |s| rest[s + 1 ..] else "";
        const question = std.mem.findScalar(u8, tail, '?');
        const path = tail[0 .. question orelse tail.len];
        const query = if (question) |q| tail[q + 1 ..] else "";
        if (slash == null and std.mem.findScalar(u8, authority, '?') != null) {
            return fail(d, error.InvalidArgument, "the options of a connection string come after a '/': mongodb://host/?appName=app", .{});
        }
        // A '@' after the first '/': a '/' in the password, unescaped.
        if (std.mem.findScalar(u8, path, '@') != null) return fail(d, error.InvalidArgument, percent_hint, .{});
        const at = std.mem.findScalarLast(u8, authority, '@');

        // Decoding never makes a part longer, and the parts do not overlap.
        const bytes = try gpa.alloc(u8, text.len);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            gpa.free(bytes);
        }
        var out: Out = .{ .bytes = bytes };
        var uri: Uri = .{ .host = "", .bytes = bytes };
        try uri.parseHost(&out, if (at) |a| authority[a + 1 ..] else authority, d);
        if (at) |a| try uri.parseUser(&out, authority[0..a], d);
        if (path.len > 0) {
            const name = out.decode(path) catch return fail(d, error.InvalidArgument, "the database of the connection string holds a '%' without two hex digits after it; write '%' as %25", .{});
            try checkDatabase(name, "the database of the connection string", d);
            uri.database = name;
        }
        var seen: std.EnumSet(Option) = .empty;
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            if (pair.len > 0) try uri.apply(&out, &seen, pair, d);
        }
        if (uri.username == null and (uri.auth_source != null or uri.auth_mechanism != null)) {
            return fail(d, error.InvalidArgument, "authSource and authMechanism go with a user: mongodb://user:password@host/?authSource=admin", .{});
        }
        return uri;
    }

    /// Wipes the strings, the user and the password among them, and frees
    /// them.
    pub fn deinit(uri: *Uri, gpa: Allocator) void {
        std.crypto.secureZero(u8, uri.bytes);
        gpa.free(uri.bytes);
        uri.* = undefined;
    }

    fn parseHost(uri: *Uri, out: *Out, hosts: []const u8, d: ?*Diagnostics) Error!void {
        if (std.mem.findScalar(u8, hosts, ',') != null) {
            return fail(d, error.Unsupported, "the connection string names several hosts, and v0.1 connects to one standalone mongod: give one host", .{});
        }
        var port: ?[]const u8 = null;
        if (hosts.len > 0 and hosts[0] == '[') {
            const close = std.mem.findScalar(u8, hosts, ']') orelse
                return fail(d, error.InvalidArgument, "the IPv6 address of the connection string has no ']': mongodb://[::1]:27017", .{});
            // A zone, as in [fe80::1%25en0], is percent-encoded.
            const literal = out.decode(hosts[1..close]) catch "";
            if (!isIp6(literal)) return fail(d, error.InvalidArgument, "'{s}' is not an IPv6 address", .{hosts[0 .. close + 1]});
            uri.host = literal;
            const after = hosts[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return fail(d, error.InvalidArgument, "after the IPv6 address of the connection string comes ':' and the port: mongodb://[::1]:27017", .{});
                port = after[1..];
            }
        } else {
            if (std.ascii.endsWithIgnoreCase(hosts, ".sock")) {
                return fail(d, error.Unsupported, "the connection string names a UNIX domain socket, and v0.1 connects over TCP: give host:port", .{});
            }
            const colon = std.mem.findScalar(u8, hosts, ':');
            if (colon) |c| if (std.mem.findScalarLast(u8, hosts, ':') != c) {
                return fail(d, error.InvalidArgument, "an IPv6 address in a connection string goes in brackets: mongodb://[::1]:27017", .{});
            };
            const name = hosts[0 .. colon orelse hosts.len];
            if (name.len == 0) return fail(d, error.InvalidArgument, "the connection string names no host: mongodb://host:27017", .{});
            // Host names are not case-sensitive.
            const lower = out.lower(name);
            Io.net.HostName.validate(lower) catch return fail(d, error.InvalidArgument, "'{s}' is not a host name or an IP address", .{name});
            uri.host = lower;
            if (colon) |c| port = hosts[c + 1 ..];
        }
        if (port) |text| uri.port = parsePort(text) orelse return fail(d, error.InvalidArgument, "the port of the connection string is a number from 1 to 65535", .{});
    }

    fn parseUser(uri: *Uri, out: *Out, info: []const u8, d: ?*Diagnostics) Error!void {
        // RFC 3986: unreserved characters, percent-encoded bytes,
        // sub-delimiters and one ':' between the user and the password.
        var colons: usize = 0;
        for (info) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '%', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => {},
            ':' => colons += 1,
            else => return fail(d, error.InvalidArgument, percent_hint, .{}),
        };
        if (colons > 1) return fail(d, error.InvalidArgument, percent_hint, .{});
        const colon = std.mem.findScalar(u8, info, ':');
        const user = out.decode(info[0 .. colon orelse info.len]) catch return fail(d, error.InvalidArgument, percent_hint, .{});
        if (user.len == 0) return fail(d, error.InvalidArgument, "the user of the connection string is empty: mongodb://user:password@host", .{});
        if (!std.unicode.utf8ValidateSlice(user)) return fail(d, error.InvalidArgument, "the user of the connection string is not UTF-8 once percent-decoded", .{});
        uri.username = user;
        if (colon) |c| uri.password = out.decode(info[c + 1 ..]) catch return fail(d, error.InvalidArgument, percent_hint, .{});
    }

    fn apply(uri: *Uri, out: *Out, seen: *std.EnumSet(Option), pair: []const u8, d: ?*Diagnostics) Error!void {
        const eq = std.mem.findScalar(u8, pair, '=') orelse
            return fail(d, error.InvalidArgument, "the option '{s}' of the connection string has no value: write {s}=value", .{ pair, pair });
        const key = pair[0..eq];
        if (key.len == 0) return fail(d, error.InvalidArgument, "an option of the connection string has no name: write name=value", .{});
        const option = Option.lookup(key) orelse {
            if (std.ascii.startsWithIgnoreCase(key, "tls") or std.ascii.startsWithIgnoreCase(key, "ssl")) {
                return fail(d, error.Unsupported, "{s}: " ++ no_tls, .{key});
            }
            log.warn("the option '{s}' of the connection string is ignored: zefir-mongo does not know it", .{key});
            return;
        };
        const name = @tagName(option);
        if (seen.contains(option)) return fail(d, error.InvalidArgument, "the option {s} is given twice in the connection string; keep one", .{name});
        seen.insert(option);
        const value = out.decode(pair[eq + 1 ..]) catch
            return fail(d, error.InvalidArgument, "the value of {s} holds a '%' without two hex digits after it; write '%' as %25", .{name});
        switch (option) {
            .authSource => {
                try checkDatabase(value, "authSource", d);
                uri.auth_source = value;
            },
            .authMechanism => uri.auth_mechanism = try mechanism(value, d),
            .appName => {
                if (value.len == 0 or value.len > max_app_name) return fail(d, error.InvalidArgument, "appName is 1 to 128 bytes long; this one is {d}", .{value.len});
                if (!std.unicode.utf8ValidateSlice(value)) return fail(d, error.InvalidArgument, "appName is not UTF-8 once percent-decoded", .{});
                uri.app_name = value;
            },
            .tls, .ssl => if (try boolean(name, value, d)) return fail(d, error.Unsupported, "{s}=true: " ++ no_tls, .{name}),
            .connectTimeoutMS => uri.connect_timeout = noneIfZero(try number(name, value, d)),
            .serverSelectionTimeoutMS => uri.server_selection_timeout = noneIfZero(try number(name, value, d)) orelse
                return fail(d, error.InvalidArgument, "serverSelectionTimeoutMS is at least 1", .{}),
            .timeoutMS => uri.timeout = noneIfZero(try number(name, value, d)),
            .maxPoolSize => {
                uri.max_pool_size = try number(name, value, d);
                if (uri.max_pool_size == 0) return fail(d, error.InvalidArgument, "maxPoolSize is at least 1: v0.1 has no pool without a limit", .{});
            },
            .maxConnecting => {
                uri.max_connecting = try number(name, value, d);
                if (uri.max_connecting == 0) return fail(d, error.InvalidArgument, "maxConnecting is at least 1", .{});
            },
            .maxIdleTimeMS => uri.max_idle_time = noneIfZero(try number(name, value, d)),
            .minPoolSize => if (try number(name, value, d) != 0) {
                return fail(d, error.Unsupported, "minPoolSize: v0.1 opens connections only when operations need them, so minPoolSize is 0", .{});
            },
            .directConnection => _ = try boolean(name, value, d),
            .retryWrites, .retryReads => if (try boolean(name, value, d)) {
                return fail(d, error.Unsupported, "{s}=true: v0.1 retries nothing; set {s}=false or leave it out", .{ name, name });
            },
            .loadBalanced => if (try boolean(name, value, d)) {
                return fail(d, error.Unsupported, "loadBalanced=true: v0.1 connects to a standalone mongod, not through a load balancer", .{});
            },
            .replicaSet, .readPreference, .readPreferenceTags, .maxStalenessSeconds => return fail(d, error.Unsupported, "{s}: " ++ standalone_only, .{name}),
            .w, .journal, .wTimeoutMS => return fail(d, error.Unsupported, "{s}: v0.1 takes no write concern from the connection string: put writeConcern in the command, or leave the server's default", .{name}),
            .readConcernLevel => return fail(d, error.Unsupported, "readConcernLevel: v0.1 takes no read concern from the connection string: put readConcern in the command, or leave the server's default", .{}),
            .socketTimeoutMS => return fail(d, error.Unsupported, "socketTimeoutMS: v0.1 bounds operations by their deadline; use timeoutMS for a default one", .{}),
            .waitQueueTimeoutMS => return fail(d, error.Unsupported, "waitQueueTimeoutMS: v0.1 bounds the wait for a connection by the deadline of the operation and serverSelectionTimeoutMS; use timeoutMS for a default deadline", .{}),
            .authMechanismProperties => return fail(d, error.Unsupported, "authMechanismProperties: it belongs to mechanisms other than SCRAM, which v0.1 does not have", .{}),
            .srvServiceName, .srvMaxHosts => return fail(d, error.Unsupported, "{s}: v0.1 does not look up SRV records", .{name}),
            .proxyHost, .proxyPort, .proxyUsername, .proxyPassword => return fail(d, error.Unsupported, "{s}: v0.1 connects without a proxy", .{name}),
            .compressors, .zlibCompressionLevel => log.warn("the option {s} of the connection string is ignored: v0.1 does not compress messages", .{name}),
            .heartbeatFrequencyMS, .serverMonitoringMode => log.warn("the option {s} of the connection string is ignored: v0.1 does not monitor the server", .{name}),
            .localThresholdMS, .serverSelectionTryOnce => log.warn("the option {s} of the connection string is ignored: with one host there is no server to select", .{name}),
            .uuidRepresentation => log.warn("the option uuidRepresentation of the connection string is ignored: a UUID is a bson.Binary of subtype 4", .{}),
        }
    }
};

const scheme = "mongodb://";
const no_tls = "TLS is not supported in v0.1; use a trusted network";
const standalone_only = "v0.1 works with a standalone mongod only; remove it from the connection string";
const percent_hint = "the user and the password in a connection string are percent-encoded: write '@' as %40, ':' as %3A, '/' as %2F and '%' as %25";

/// The options the driver knows, spelled as the specification spells them.
const Option = enum {
    authSource,
    authMechanism,
    appName,
    tls,
    ssl,
    connectTimeoutMS,
    serverSelectionTimeoutMS,
    timeoutMS,
    maxPoolSize,
    minPoolSize,
    maxConnecting,
    maxIdleTimeMS,
    directConnection,
    retryWrites,
    retryReads,
    loadBalanced,
    replicaSet,
    readPreference,
    readPreferenceTags,
    maxStalenessSeconds,
    w,
    journal,
    wTimeoutMS,
    readConcernLevel,
    socketTimeoutMS,
    waitQueueTimeoutMS,
    authMechanismProperties,
    srvServiceName,
    srvMaxHosts,
    proxyHost,
    proxyPort,
    proxyUsername,
    proxyPassword,
    compressors,
    zlibCompressionLevel,
    heartbeatFrequencyMS,
    serverMonitoringMode,
    localThresholdMS,
    serverSelectionTryOnce,
    uuidRepresentation,

    fn lookup(key: []const u8) ?Option {
        for (std.enums.values(Option)) |option| {
            if (std.ascii.eqlIgnoreCase(key, @tagName(option))) return option;
        }
        return null;
    }
};

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
    if (text.len == 0 or text.len > 5) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (port == 0) null else port;
}

/// A database name, as `mongo.Client` takes one for `$db`: 1 to 63 bytes,
/// without NUL and without any of `/\. "$`.
fn checkDatabase(name: []const u8, what: []const u8, d: ?*Diagnostics) Uri.Error!void {
    if (name.len == 0 or name.len > 63) return fail(d, error.InvalidArgument, "{s} is a database name of 1 to 63 bytes; this one is {d}", .{ what, name.len });
    if (std.mem.findAny(u8, name, "\x00/\\. \"$") != null) {
        return fail(d, error.InvalidArgument, "{s} is a database name, without / \\ . \" $, a space or NUL", .{what});
    }
}

fn mechanism(value: []const u8, d: ?*Diagnostics) Uri.Error!Uri.Mechanism {
    for (std.enums.values(Uri.Mechanism)) |m| {
        if (std.mem.eql(u8, value, m.name())) return m;
    }
    for ([_][]const u8{ "MONGODB-X509", "PLAIN", "GSSAPI", "MONGODB-AWS", "MONGODB-OIDC", "MONGODB-CR", "SCRAM-SHA-512" }) |other| {
        if (std.mem.eql(u8, value, other)) return fail(d, error.Unsupported, "authMechanism={s}: v0.1 authenticates with SCRAM-SHA-256 or SCRAM-SHA-1 only", .{value});
    }
    return fail(d, error.InvalidArgument, "authMechanism is SCRAM-SHA-256 or SCRAM-SHA-1, as written here; got '{s}'", .{value});
}

fn boolean(name: []const u8, value: []const u8, d: ?*Diagnostics) Uri.Error!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return fail(d, error.InvalidArgument, "{s} is true or false; got '{s}'", .{ name, value });
}

fn number(name: []const u8, value: []const u8, d: ?*Diagnostics) Uri.Error!u32 {
    const valid = value.len > 0 and value.len <= 10 and for (value) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    if (valid) if (std.fmt.parseInt(u32, value, 10)) |n| return n else |_| {};
    return fail(d, error.InvalidArgument, "{s} is a whole number from 0 to 4294967295; got '{s}'", .{ name, value });
}

/// Milliseconds, or null for 0.
fn noneIfZero(ms: u32) ?Io.Duration {
    return if (ms == 0) null else .fromMilliseconds(ms);
}

fn fail(d: ?*Diagnostics, err: Uri.Error, comptime fmt: []const u8, args: anytype) Uri.Error {
    if (d) |x| x.set(null, null, fmt, args);
    return err;
}
