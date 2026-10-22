//! The first exchanges of every connection, before it serves a call:
//!
//! 1. `HELLO 3 [AUTH <user> <password>] [SETNAME <name>]`, alone and
//!    first: before authentication a server reads one command at a time,
//!    and the reply decides whether the client talks to it at all. A
//!    password without a user in the URL is that of the user `default`;
//!    without a password there is no AUTH.
//! 2. The reply is checked: `proto` 3; `server` redis of version 7.2 or
//!    later, or valkey of 8 or later; `mode` standalone; `role` master or
//!    replica. Anything else is `error.Unsupported`, with what came. The
//!    connection keeps the server's number of it, `id`, and the round
//!    trip of HELLO.
//! 3. In one write: `CLIENT SETINFO LIB-NAME zefir-redis`, `CLIENT SETINFO
//!    LIB-VER <the version of zefir>` and, for a database other than 0,
//!    `SELECT`. An error of SETINFO is skipped, as its documentation asks,
//!    and logged at debug.
//!
//! | Step   | Reply                                             | Error                                               |
//! |--------|---------------------------------------------------|-----------------------------------------------------|
//! | HELLO  | `-WRONGPASS`                                      | `AuthenticationFailed`, with the server's text      |
//! | HELLO  | `-NOAUTH`                                         | `AuthenticationFailed`: the server wants a password |
//! | HELLO  | `-NOPROTO`                                        | `Unsupported`: no RESP3                             |
//! | HELLO  | `-ERR unknown command`: no HELLO, a server before 6.0 | `Unsupported`                                   |
//! | HELLO  | another error: `DENIED`, `ERR max number of clients reached`, `NOPERM` | `Unavailable`, with the server's text |
//! | HELLO  | a map of a server that v0.1 does not take         | `Unsupported`, with what came                       |
//! | SELECT | `-ERR DB index is out of range`                   | `InvalidArgument`: the database is not there        |
//! | SELECT | another error, such as `BUSY`                     | `Unavailable`, with the server's text               |
//! | any    | the end of the stream, a reset                    | `Unavailable`                                       |
//!
//! A refusal is logged as a warning with the address of the server, the
//! error and the reason. A password never is: the buffer that HELLO went
//! out from is wiped, and the error of a server without HELLO, which
//! quotes HELLO's arguments, the password among them, goes neither to the
//! diagnostics nor to the log: it is read into one buffer, with no copy,
//! and that buffer is wiped, as is what the connection read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const resp = @import("../resp.zig");
const cmd = @import("../cmd.zig");
const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const OwnedOptions = @import("../OwnedOptions.zig");
const Address = @import("Address.zig");
const Connection = @import("Connection.zig");
const time = @import("time.zig");
const log = std.log.scoped(.redis);

pub const lib_name = "zefir-redis";
/// The version of the zefir package, from its build.zig.zon.
pub const lib_version: []const u8 = @import("build_options").version;

/// What every new connection of a client says in its handshake.
pub const Setup = struct {
    /// Who HELLO authenticates as; null: no AUTH.
    auth: ?Auth = null,
    /// HELLO's SETNAME; null: none.
    client_name: ?[]const u8 = null,
    /// The database that SELECT picks; 0: no SELECT.
    database: u32 = 0,
};

pub const Auth = struct {
    username: []const u8,
    password: []const u8,
};

/// The setup of the connections of a client with `options`, which must
/// outlive it.
pub fn setupOf(options: *const OwnedOptions) Setup {
    return .{
        .auth = if (options.credentials()) |c| .{ .username = c.username, .password = c.password } else null,
        .client_name = options.client_name,
        .database = options.url.database,
    };
}

pub const Error = error{
    /// The connection broke, or the server refused it for a reason that
    /// may pass; the diagnostics say which.
    Unavailable,
    /// The server is not one that v0.1 talks to.
    Unsupported,
    /// The server refused the user or the password, or wants a password.
    AuthenticationFailed,
    /// The server has no database of the URL's number.
    InvalidArgument,
    OutOfMemory,
    /// The task was canceled, and stays canceled.
    Canceled,
};

const needs = "v0.1 needs Redis 7.2 or later, or Valkey 8 or later";

/// Shakes hands on `conn`: HELLO, its check, then SETINFO and SELECT. The
/// connection keeps the server's id of it and the round trip of HELLO.
pub fn run(conn: *Connection, setup: Setup, d: *Diagnostics) Error!void {
    var refusal: Refusal = .{};
    return runWith(conn, setup, d, &refusal);
}

/// `run`, reading the text of HELLO's refusal into `refusal` and nowhere
/// else. A server without HELLO quotes the password in it, so `refusal`
/// is wiped before it returns, whatever came.
pub fn runWith(conn: *Connection, setup: Setup, d: *Diagnostics, refusal: *Refusal) Error!void {
    defer std.crypto.secureZero(u8, &refusal.buffer);
    const io = conn.stream.io;
    const start = time.now(io);
    const exchanged = conn.exchange(Hello{ .setup = &setup, .address = conn.address, .refusal = refusal }, null, null, d);
    // HELLO carried the password: the buffer it went out from forgets it.
    if (setup.auth != null) std.crypto.secureZero(u8, &conn.write_buffer);
    var answer = exchanged catch |err| return failed(conn, err, d);
    conn.rtt = start.durationTo(time.now(io));
    switch (answer) {
        .refused => {
            // A server without HELLO quoted the password in what the
            // connection read too.
            defer std.crypto.secureZero(u8, &conn.read_buffer);
            return refused(conn, refusal.text(), d);
        },
        .server => |*info| {
            try check(conn, info, d);
            conn.id = info.id;
        },
    }
    try setUp(conn, setup, d);
}

/// HELLO, as a command of the handshake's own: its reply is the fields of
/// the server, or its refusal, read without memory.
const Hello = struct {
    setup: *const Setup,
    /// The server, for the texts of errors.
    address: Address,
    /// Where the text of a refusal goes: no copy of it is made.
    refusal: *Refusal,

    pub const Reply = Answer;

    pub fn check(_: Hello, _: ?*Diagnostics) error{InvalidArgument}!void {}

    pub fn write(h: Hello, w: resp.Writer) resp.Writer.Error!void {
        const s = h.setup;
        var n: usize = 2;
        if (s.auth != null) n += 3;
        if (s.client_name != null) n += 2;
        try w.arrayHeader(n);
        try w.bulk("HELLO");
        try w.bulk("3");
        if (s.auth) |auth| {
            try w.bulk("AUTH");
            try w.bulk(auth.username);
            try w.bulk(auth.password);
        }
        if (s.client_name) |name| {
            try w.bulk("SETNAME");
            try w.bulk(name);
        }
    }

    pub fn read(h: Hello, r: *resp.Reader, _: ?Allocator, d: ?*Diagnostics) resp.DecodeError!Answer {
        const first = try r.next();
        switch (first) {
            .simple_error, .bulk_error => {
                h.refusal.len = (try r.payloadPrefix(&h.refusal.buffer)).bytes.len;
                return .refused;
            },
            .map => |pairs| {
                var info: Info = .{};
                for (0..pairs) |_| try h.readField(r, &info, d);
                return .{ .server = info };
            },
            else => {
                const kind = try kindOf(r, first);
                try r.skipReply();
                if (d) |x| x.set(.handshake, null, "the server at {f} answered HELLO with {f}, not a map: " ++ needs, .{ h.address, kind });
                return error.UnexpectedReply;
            },
        }
    }

    /// Reads one pair of the map into `info`, or skips it.
    fn readField(h: Hello, r: *resp.Reader, info: *Info, d: ?*Diagnostics) resp.DecodeError!void {
        var name_buffer: [16]u8 = undefined;
        const key = try r.next();
        const name: []const u8 = switch (key) {
            .simple_string, .bulk_string, .verbatim_string => blk: {
                const prefix = try r.payloadPrefix(&name_buffer);
                break :blk if (prefix.len == prefix.bytes.len) prefix.bytes else "";
            },
            else => blk: {
                try r.skipElement();
                break :blk "";
            },
        };
        const value = try r.next();
        inline for (.{ "server", "version", "mode", "role" }) |field| {
            if (std.mem.eql(u8, name, field)) return h.readString(r, value, &@field(info, field), field, d);
        }
        inline for (.{ "proto", "id" }) |field| {
            if (std.mem.eql(u8, name, field)) {
                if (value != .integer) return h.mismatch(r, value, field, "an integer", d);
                @field(info, field) = value.integer;
                return;
            }
        }
        try r.skipElement();
    }

    fn readString(h: Hello, r: *resp.Reader, value: resp.Reader.Element, field: *Field, comptime name: []const u8, d: ?*Diagnostics) resp.DecodeError!void {
        switch (value) {
            .simple_string, .bulk_string, .verbatim_string => {
                const prefix = try r.payloadPrefix(&field.buffer);
                for (prefix.bytes) |*c| {
                    if (c.* < 0x20 or c.* > 0x7E) c.* = '?';
                }
                field.len = prefix.bytes.len;
                field.present = true;
            },
            else => return h.mismatch(r, value, name, "a string", d),
        }
    }

    /// UnexpectedReply about the field `name`, whose value `value` is not
    /// `wanted`, once the reply is read to its end.
    fn mismatch(h: Hello, r: *resp.Reader, value: resp.Reader.Element, comptime name: []const u8, comptime wanted: []const u8, d: ?*Diagnostics) resp.DecodeError {
        const kind = kindOf(r, value) catch |err| return err;
        r.skipReply() catch |err| return err;
        if (d) |x| x.set(.handshake, null, "the field '" ++ name ++ "' of the reply to HELLO from {f} is {f}, not " ++ wanted, .{ h.address, kind });
        return error.UnexpectedReply;
    }
};

/// What came, for a text: the length of a simple string is known only
/// once it is read.
fn kindOf(r: *resp.Reader, element: resp.Reader.Element) resp.Reader.Error!resp.Kind {
    var len: ?usize = null;
    if (element == .simple_string) {
        var none: [0]u8 = undefined;
        len = (try r.payloadPrefix(&none)).len;
    }
    return .{ .element = element, .len = len };
}

/// What HELLO got: the fields of the server, or a refusal, whose text is
/// in `Hello.refusal`.
const Answer = union(enum) {
    server: Info,
    refused,
};

/// The fields of HELLO's map that the check reads.
const Info = struct {
    server: Field = .{},
    version: Field = .{},
    mode: Field = .{},
    role: Field = .{},
    proto: ?i64 = null,
    id: ?i64 = null,
};

/// A string of HELLO's map: its first 64 bytes, each outside printable
/// ASCII made '?', so that a text about it shows no control bytes.
const Field = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,
    present: bool = false,

    fn get(f: *const Field) ?[]const u8 {
        return if (f.present) f.buffer[0..f.len] else null;
    }
};

/// The text of HELLO's error: as much of it as `Diagnostics` keeps.
pub const Refusal = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn text(r: *const Refusal) []const u8 {
        return r.buffer[0..r.len];
    }
};

const Kind = enum {
    redis,
    valkey,

    fn name(k: Kind) []const u8 {
        return switch (k) {
            .redis => "Redis",
            .valkey => "Valkey",
        };
    }
};

/// The major and minor version of a server: "8.10.2" is 8.10, and what
/// follows the minor version, such as ".0-rc1", does not count.
const Version = struct {
    major: u32,
    minor: u32,

    fn parse(text: []const u8) ?Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        const major = number(parts.next() orelse return null) orelse return null;
        const minor = number(parts.next() orelse return null) orelse return null;
        return .{ .major = major, .minor = minor };
    }

    fn below(v: Version, major: u32, minor: u32) bool {
        return v.major < major or (v.major == major and v.minor < minor);
    }

    fn number(text: []const u8) ?u32 {
        if (text.len == 0 or text.len > 9) return null;
        for (text) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(u32, text, 10) catch null;
    }
};

/// The server of `info` is one that v0.1 talks to: RESP3, Redis 7.2 or
/// later or Valkey 8 or later, standalone, master or replica.
fn check(conn: *Connection, info: *const Info, d: *Diagnostics) Error!void {
    const at = conn.address;
    const proto = info.proto orelse return unsupported(conn, d, "the reply to HELLO from {f} has no proto", .{at});
    if (proto != 3) return unsupported(conn, d, "the server at {f} answered HELLO 3 with proto {d}: v0.1 speaks RESP3 only", .{ at, proto });
    const server = info.server.get() orelse return unsupported(conn, d, "the reply to HELLO from {f} has no server", .{at});
    const version = info.version.get() orelse return unsupported(conn, d, "the reply to HELLO from {f} has no version", .{at});
    const kind: Kind = if (std.mem.eql(u8, server, "redis")) .redis else if (std.mem.eql(u8, server, "valkey")) .valkey else {
        return unsupported(conn, d, "the server at {f} is '{s}' {s}, neither Redis nor Valkey: " ++ needs, .{ at, server, version });
    };
    const parsed = Version.parse(version) orelse
        return unsupported(conn, d, "the server at {f} is {s} of the version '{s}', which does not read: " ++ needs, .{ at, kind.name(), version });
    switch (kind) {
        .redis => if (parsed.below(7, 2)) return unsupported(conn, d, "the server at {f} is Redis {s}; v0.1 needs Redis 7.2 or later", .{ at, version }),
        .valkey => if (parsed.below(8, 0)) return unsupported(conn, d, "the server at {f} is Valkey {s}; v0.1 needs Valkey 8 or later", .{ at, version }),
    }
    const mode = info.mode.get() orelse return unsupported(conn, d, "the reply to HELLO from {f} has no mode", .{at});
    if (std.mem.eql(u8, mode, "cluster")) return unsupported(conn, d, "the server at {f} is a cluster node; v0.1 talks to one standalone server", .{at});
    if (std.mem.eql(u8, mode, "sentinel")) return unsupported(conn, d, "the server at {f} is a Sentinel; v0.1 talks to one standalone server", .{at});
    if (!std.mem.eql(u8, mode, "standalone")) return unsupported(conn, d, "the server at {f} runs in the mode '{s}'; v0.1 talks to one standalone server", .{ at, mode });
    const role = info.role.get() orelse return unsupported(conn, d, "the reply to HELLO from {f} has no role", .{at});
    if (!std.mem.eql(u8, role, "master") and !std.mem.eql(u8, role, "replica")) {
        return unsupported(conn, d, "the server at {f} has the role '{s}'; v0.1 talks to a master or a replica", .{ at, role });
    }
}

/// The error of HELLO's refusal, whose text the server sent.
fn refused(conn: *Connection, text: []const u8, d: *Diagnostics) Error {
    const code = text[0 .. std.mem.findScalar(u8, text, ' ') orelse text.len];
    if (std.mem.eql(u8, code, "WRONGPASS")) {
        d.setServer(.handshake, text);
        return refuse(conn, error.AuthenticationFailed, d);
    }
    if (std.mem.eql(u8, code, "NOAUTH")) {
        d.set(.handshake, null, "the server wants a password: set it in the URL or in Options.password", .{});
        return refuse(conn, error.AuthenticationFailed, d);
    }
    if (std.mem.eql(u8, code, "NOPROTO")) {
        d.set(.handshake, null, "the server at {f} does not speak RESP3: " ++ needs, .{conn.address});
        return refuse(conn, error.Unsupported, d);
    }
    // A server before 6.0, which quotes the arguments, the password among
    // them, in this text.
    if (std.mem.eql(u8, code, "ERR") and std.ascii.findIgnoreCase(text, "unknown command") != null) {
        d.set(.handshake, null, "the server has no HELLO: " ++ needs, .{});
        return refuse(conn, error.Unsupported, d);
    }
    d.setServer(.handshake, text);
    return refuse(conn, error.Unavailable, d);
}

/// SETINFO and SELECT, in one write, and their replies.
fn setUp(conn: *Connection, setup: Setup, d: *Diagnostics) Error!void {
    const name = cmd.raw(void, .{ "CLIENT", "SETINFO", "LIB-NAME", lib_name });
    const version = cmd.raw(void, .{ "CLIENT", "SETINFO", "LIB-VER", lib_version });
    const select = cmd.raw(void, .{ "SELECT", setup.database });
    conn.begin(null);
    conn.write(name, d) catch |err| return failed(conn, err, d);
    conn.write(version, d) catch |err| return failed(conn, err, d);
    if (setup.database != 0) conn.write(select, d) catch |err| return failed(conn, err, d);
    conn.flush(d) catch |err| return failed(conn, err, d);
    try setInfo(conn, name, "LIB-NAME", d);
    try setInfo(conn, version, "LIB-VER", d);
    if (setup.database != 0) try selectDatabase(conn, select, setup.database, d);
}

/// The reply to `CLIENT SETINFO`: an error is skipped.
fn setInfo(conn: *Connection, command: anytype, comptime what: []const u8, d: *Diagnostics) Error!void {
    conn.receive(command, null, d) catch |err| switch (err) {
        error.ServerError => {
            log.debug("{f} refused CLIENT SETINFO " ++ what ++ " ({f}); skipped", .{ conn.address, Printable{ .text = d.code() } });
            d.* = .{};
        },
        else => return failed(conn, err, d),
    };
}

fn selectDatabase(conn: *Connection, command: anytype, database: u32, d: *Diagnostics) Error!void {
    conn.receive(command, null, d) catch |err| switch (err) {
        error.ServerError => {
            if (std.mem.find(u8, d.message(), "DB index is out of range") != null) {
                d.set(.handshake, null, "database {d} of the URL is not on the server", .{database});
                return refuse(conn, error.InvalidArgument, d);
            }
            d.phase = .handshake;
            return refuse(conn, error.Unavailable, d);
        },
        else => return failed(conn, err, d),
    };
}

/// The error of a handshake whose exchange failed.
fn failed(conn: *Connection, err: errors.Error, d: *Diagnostics) Error {
    d.phase = .handshake;
    switch (err) {
        error.Interrupted => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        // HELLO's own reading said what came.
        error.UnexpectedReply => return refuse(conn, error.Unsupported, d),
        error.ConnectionLost => {
            // The end of the stream, or a reset.
            const closed = if (conn.stream.err) |cause| cause == error.ConnectionResetByPeer else true;
            if (closed) d.set(.handshake, conn.stream.err, "the server at {f} closed the connection during the handshake; a server that requires TLS does so, and v0.1 does not speak TLS", .{conn.address});
            return error.Unavailable;
        },
        error.ProtocolViolation => {
            d.set(.handshake, null, "the server at {f} answered the handshake with bytes that are not RESP3", .{conn.address});
            return error.Unavailable;
        },
        else => return error.Unavailable,
    }
}

fn unsupported(conn: *Connection, d: *Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    d.set(.handshake, null, fmt, args);
    return refuse(conn, error.Unsupported, d);
}

/// Logs the refusal of the server at `conn` and returns `err`.
fn refuse(conn: *Connection, err: Error, d: *const Diagnostics) Error {
    log.warn("{f} refused the connection: {t}: {f}", .{ conn.address, err, Printable{ .text = d.message() } });
    return err;
}

/// A text for the log, each byte outside printable ASCII shown as '?'.
const Printable = struct {
    text: []const u8,

    pub fn format(p: Printable, w: *Io.Writer) Io.Writer.Error!void {
        for (p.text) |c| try w.writeByte(if (c >= 0x20 and c <= 0x7E) c else '?');
    }
};
