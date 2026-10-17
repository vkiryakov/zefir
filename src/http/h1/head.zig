//! The head of an HTTP/1.1 request, parsed by RFC 9112 and stricter than
//! most servers: the request line, the header fields, and what they say
//! about the body and the connection. Pure: bytes in, a head out; no I/O,
//! no allocation.
//!
//! The connection reads into its buffer and passes everything it holds to
//! `parseHead`. A null head means "need more": read more after the bytes
//! and call again with all of them. The buffer holds `max_head_bytes`, so
//! a null never comes with a full buffer. An error is the status to answer
//! with (`statusOf`) before closing the connection: what follows a broken
//! head can't be trusted to start a request. A head gives the request; its
//! slices point into the bytes passed, and its body, if any, starts at
//! `len` (by `framing`).
//!
//! A byte that breaks a rule is refused where it stands, in the order the
//! bytes come, so a head cut anywhere gives the same answer once the rest
//! arrives. What the fields mean together (`Host`, the length of the body,
//! `Connection`, `Expect`) is checked once the head is complete: first
//! what makes a request malformed (400), then a transfer coding we don't
//! know (501), then an expectation we can't meet (417).

const std = @import("std");

pub const Version = enum { http10, http11 };

/// A header field as it came: the name in its case, the value without the
/// whitespace around it.
pub const Field = struct { name: []const u8, value: []const u8 };

pub const Limits = struct {
    /// The whole head: the request line, the fields and the empty line,
    /// empty lines before the request line included. Over it: 431.
    max_head_bytes: u32 = 16 << 10,
    /// Header fields, each line counted. Over it: 431.
    max_header_fields: u16 = 100,
    /// The request target. Over it: 414.
    max_target_bytes: u32 = 8 << 10,
};

/// How the body is delimited: none, `Content-Length` bytes, or chunked
/// (h1/chunked.zig decodes it).
pub const Framing = union(enum) { none, length: u64, chunked };

pub const Head = struct {
    method: std.http.Method,
    /// Origin form (`/path?query`), absolute form (`http://host/path`), or
    /// `*` for OPTIONS.
    target: []const u8,
    version: Version,
    /// A prefix of the caller's storage.
    fields: []const Field,
    framing: Framing,
    /// The connection may carry another request after this one: HTTP/1.1
    /// without `Connection: close`, HTTP/1.0 with `Connection: keep-alive`.
    keep_alive: bool,
    /// HTTP/1.1 with `Expect: 100-continue`: answer 100 before reading the
    /// body.
    expect_continue: bool,
    /// Bytes up to and including the final CRLF CRLF.
    len: usize,
};

pub const Error = error{
    /// A head that breaks the syntax or the rules of RFC 9112: 400.
    BadRequest,
    /// A target over `max_target_bytes`: 414.
    TargetTooLong,
    /// A head over `max_head_bytes` or `max_header_fields`: 431.
    HeadTooLarge,
    /// A method that is not one of `std.http.Method`, or a transfer coding
    /// other than chunked alone: 501.
    NotImplemented,
    /// A major version other than 1: 505.
    VersionNotSupported,
    /// An `Expect` other than `100-continue`: 417.
    ExpectationFailed,
};

/// Parses the head at the start of `input` into `fields`, which should
/// hold `limits.max_header_fields` (fewer lowers that limit). Null: no
/// complete head in `input` yet, and `input.len < limits.max_head_bytes`.
pub fn parseHead(input: []const u8, limits: Limits, fields: []Field) Error!?Head {
    const window = input[0..@min(input.len, limits.max_head_bytes)];
    return scan(window, limits, fields) catch |err| switch (err) {
        error.NeedMore => if (input.len >= limits.max_head_bytes) error.HeadTooLarge else null,
        else => |e| e,
    };
}

/// The status of the answer to a head that failed with `err`.
pub fn statusOf(err: Error) u16 {
    return switch (err) {
        error.BadRequest => 400,
        error.TargetTooLong => 414,
        error.HeadTooLarge => 431,
        error.NotImplemented => 501,
        error.VersionNotSupported => 505,
        error.ExpectationFailed => 417,
    };
}

/// The value of the first field named `name`, in any case.
pub fn fieldValue(fields: []const Field, name: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, name)) return field.value;
    }
    return null;
}

const ScanError = Error || error{NeedMore};

fn scan(w: []const u8, limits: Limits, storage: []Field) ScanError!Head {
    var pos: usize = 0;

    // Empty lines before the request line are skipped (RFC 9112 §2.2).
    while (try byteAt(w, pos) == '\r') {
        try expectLf(w, pos + 1);
        pos += 2;
    }

    // method SP request-target SP HTTP-version CRLF (RFC 9112 §3), with
    // single spaces.
    const method_start = pos;
    while (true) : (pos += 1) {
        const c = try byteAt(w, pos);
        if (c == ' ') break;
        if (!isToken(c)) return error.BadRequest;
    }
    if (pos == method_start) return error.BadRequest;
    const method = std.meta.stringToEnum(std.http.Method, w[method_start..pos]) orelse
        return error.NotImplemented;
    pos += 1;

    const target_start = pos;
    while (true) : (pos += 1) {
        const c = try byteAt(w, pos);
        if (c == ' ') break;
        // Visible ASCII only: a URI has no spaces, controls or raw UTF-8.
        if (c < 0x21 or c > 0x7e) return error.BadRequest;
        if (pos - target_start == limits.max_target_bytes) return error.TargetTooLong;
    }
    const target = w[target_start..pos];
    try checkTarget(method, target);
    pos += 1;

    const version = try scanVersion(w, &pos);

    // field-name ":" OWS field-value OWS CRLF, up to an empty line.
    const max_fields = @min(storage.len, limits.max_header_fields);
    var count: usize = 0;
    while (true) {
        if (try byteAt(w, pos) == '\r') {
            try expectLf(w, pos + 1);
            pos += 2;
            break;
        }
        if (count == max_fields) return error.HeadTooLarge;
        // A name is a token, right before ':'. So a line that starts with
        // whitespace (obs-fold, or whitespace before the first field), a
        // space before ':' and a bare LF are all refused here.
        const name_start = pos;
        while (true) : (pos += 1) {
            const c = try byteAt(w, pos);
            if (c == ':') break;
            if (!isToken(c)) return error.BadRequest;
        }
        if (pos == name_start) return error.BadRequest;
        const name = w[name_start..pos];
        pos += 1;
        while (true) : (pos += 1) {
            const c = try byteAt(w, pos);
            if (c != ' ' and c != '\t') break;
        }
        const value_start = pos;
        while (true) : (pos += 1) {
            const c = try byteAt(w, pos);
            if (c == '\r') break;
            if (!isValueChar(c)) return error.BadRequest;
        }
        const value = std.mem.trimEnd(u8, w[value_start..pos], " \t");
        try expectLf(w, pos + 1);
        pos += 2;
        storage[count] = .{ .name = name, .value = value };
        count += 1;
    }
    const fields = storage[0..count];

    try checkHost(version, fields);
    var transfer_encoding = false;
    var lengths: usize = 0;
    var length_value: []const u8 = "";
    for (fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, "transfer-encoding")) {
            transfer_encoding = true;
        } else if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
            lengths += 1;
            length_value = field.value;
        }
    }
    var framing: Framing = .none;
    if (transfer_encoding) {
        // HTTP/1.0 has no transfer codings, and a length beside one is the
        // classic request smuggling (RFC 9112 §6.1, §6.3).
        if (version == .http10 or lengths > 0) return error.BadRequest;
    } else if (lengths > 0) {
        // Even two equal lengths are refused: some other parser may take
        // the second one.
        if (lengths > 1) return error.BadRequest;
        framing = .{ .length = try parseLength(length_value) };
    }
    const keep_alive = try keepAliveOf(version, fields);
    if (transfer_encoding) {
        if (!chunkedOnly(fields)) return error.NotImplemented;
        framing = .chunked;
    }
    // An HTTP/1.0 client can't expect anything (RFC 9110 §10.1.1).
    const expect_continue = version == .http11 and try expectsContinue(fields);

    return .{
        .method = method,
        .target = target,
        .version = version,
        .fields = fields,
        .framing = framing,
        .keep_alive = keep_alive,
        .expect_continue = expect_continue,
        .len = pos,
    };
}

fn byteAt(w: []const u8, pos: usize) error{NeedMore}!u8 {
    if (pos >= w.len) return error.NeedMore;
    return w[pos];
}

/// The LF of a CRLF whose CR is right before `pos`.
fn expectLf(w: []const u8, pos: usize) ScanError!void {
    if (try byteAt(w, pos) != '\n') return error.BadRequest;
}

/// Origin form, absolute form with http or https and an authority, or `*`
/// for OPTIONS. The authority form of CONNECT is refused, and so is user
/// info in an authority, as in `Host` (RFC 9110 §4.2.4).
fn checkTarget(method: std.http.Method, target: []const u8) Error!void {
    if (target.len == 0) return error.BadRequest;
    if (target[0] == '/') return;
    if (std.mem.eql(u8, target, "*")) {
        if (method != .OPTIONS) return error.BadRequest;
        return;
    }
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(target, scheme)) {
            const rest = target[scheme.len..];
            if (rest.len == 0 or rest[0] == '/' or rest[0] == '?' or rest[0] == '#') return error.BadRequest;
            const authority = rest[0 .. std.mem.findAny(u8, rest, "/?#") orelse rest.len];
            if (std.mem.findScalar(u8, authority, '@') != null) return error.BadRequest;
            return;
        }
    }
    return error.BadRequest;
}

/// "HTTP/" DIGIT "." DIGIT CRLF. A major version other than 1 is 505 as
/// soon as its digit comes; 1.x for x > 1 is served as 1.1 (RFC 9110
/// §2.5).
fn scanVersion(w: []const u8, pos: *usize) ScanError!Version {
    for ("HTTP/") |expected| {
        if (try byteAt(w, pos.*) != expected) return error.BadRequest;
        pos.* += 1;
    }
    const major = try byteAt(w, pos.*);
    if (!std.ascii.isDigit(major)) return error.BadRequest;
    if (major != '1') return error.VersionNotSupported;
    if (try byteAt(w, pos.* + 1) != '.') return error.BadRequest;
    const minor = try byteAt(w, pos.* + 2);
    if (!std.ascii.isDigit(minor)) return error.BadRequest;
    if (try byteAt(w, pos.* + 3) != '\r') return error.BadRequest;
    try expectLf(w, pos.* + 4);
    pos.* += 5;
    return if (minor == '0') .http10 else .http11;
}

/// Exactly one `Host` in HTTP/1.1, at most one in HTTP/1.0, and a value
/// that is a host with an optional port (RFC 9112 §3.2). An empty value
/// is allowed.
fn checkHost(version: Version, fields: []const Field) Error!void {
    var hosts: usize = 0;
    for (fields) |field| {
        if (!std.ascii.eqlIgnoreCase(field.name, "host")) continue;
        hosts += 1;
        for (field.value) |c| {
            if (!host_chars[c]) return error.BadRequest;
        }
    }
    if (hosts > 1 or (hosts == 0 and version == .http11)) return error.BadRequest;
}

/// 1*DIGIT that fits in u64.
fn parseLength(value: []const u8) Error!u64 {
    if (value.len == 0) return error.BadRequest;
    var length: u64 = 0;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return error.BadRequest;
        const times_ten = @mulWithOverflow(length, 10);
        const plus_digit = @addWithOverflow(times_ten[0], c - '0');
        if (times_ten[1] != 0 or plus_digit[1] != 0) return error.BadRequest;
        length = plus_digit[0];
    }
    return length;
}

/// `Connection` is a list of tokens over all its fields; empty elements
/// are skipped (RFC 9110 §5.6.1, §7.6.1).
fn keepAliveOf(version: Version, fields: []const Field) Error!bool {
    var close = false;
    var keep_alive = false;
    var elements: ListIterator = .{ .fields = fields, .name = "connection" };
    while (elements.next()) |element| {
        if (element.len == 0) continue;
        for (element) |c| {
            if (!isToken(c)) return error.BadRequest;
        }
        if (std.ascii.eqlIgnoreCase(element, "close")) close = true;
        if (std.ascii.eqlIgnoreCase(element, "keep-alive")) keep_alive = true;
    }
    return switch (version) {
        .http11 => !close,
        .http10 => keep_alive and !close,
    };
}

/// The transfer codings of all `Transfer-Encoding` fields are one
/// element, `chunked`. Anything else (another coding, chunked twice, an
/// empty element) is a framing we don't take.
fn chunkedOnly(fields: []const Field) bool {
    var elements: ListIterator = .{ .fields = fields, .name = "transfer-encoding" };
    const first = elements.next() orelse return false;
    return std.ascii.eqlIgnoreCase(first, "chunked") and elements.next() == null;
}

/// True for one `Expect` of exactly `100-continue`, false for none.
fn expectsContinue(fields: []const Field) Error!bool {
    var elements: ListIterator = .{ .fields = fields, .name = "expect" };
    const first = elements.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, "100-continue") or elements.next() != null) return error.ExpectationFailed;
    return true;
}

/// The elements of a comma-separated list over every field of one name,
/// trimmed of whitespace, empty ones included.
const ListIterator = struct {
    fields: []const Field,
    name: []const u8,
    index: usize = 0,
    /// The part of the current field's value not yet given.
    rest: ?[]const u8 = null,

    fn next(it: *ListIterator) ?[]const u8 {
        if (it.rest == null) {
            while (it.index < it.fields.len) {
                const field = it.fields[it.index];
                it.index += 1;
                if (std.ascii.eqlIgnoreCase(field.name, it.name)) {
                    it.rest = field.value;
                    break;
                }
            } else return null;
        }
        const rest = it.rest.?;
        if (std.mem.findScalar(u8, rest, ',')) |comma| {
            it.rest = rest[comma + 1 ..];
            return std.mem.trim(u8, rest[0..comma], " \t");
        }
        it.rest = null;
        return std.mem.trim(u8, rest, " \t");
    }
};

fn charTable(comptime chars: []const u8) [256]bool {
    var table: [256]bool = @splat(false);
    for (chars) |c| table[c] = true;
    return table;
}

const alnum = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

const token_chars = charTable("!#$%&'*+-.^_`|~" ++ alnum);

/// uri-host [ ":" port ]: unreserved, pct-encoded, sub-delims, the
/// brackets of an IP literal and ':' (RFC 3986 §3.2.2).
const host_chars = charTable("-._~%!$&'()*+,;=:[]" ++ alnum);

/// tchar (RFC 9110 §5.6.2): a byte of a method, a field name, a list
/// element or a chunk extension.
pub fn isToken(c: u8) bool {
    return token_chars[c];
}

/// field-vchar, SP or HTAB (RFC 9110 §5.5): no CTL but HTAB, no DEL.
pub fn isValueChar(c: u8) bool {
    return c == '\t' or (c >= 0x20 and c != 0x7f);
}

const testing = std.testing;
const cases = @import("testdata/cases.zig");

fn parse(raw: []const u8, storage: []Field) Error!?Head {
    return parseHead(raw, .{}, storage);
}

test "parseHead: a GET with Host gives method, target, version and fields" {
    var storage: [100]Field = undefined;
    const raw = "GET /users/42?full=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nX-Empty:\r\n\r\n";
    const h = (try parse(raw, &storage)).?;
    try testing.expectEqual(std.http.Method.GET, h.method);
    try testing.expectEqualStrings("/users/42?full=1", h.target);
    try testing.expectEqual(Version.http11, h.version);
    try testing.expectEqual(3, h.fields.len);
    try testing.expectEqualStrings("Host", h.fields[0].name);
    try testing.expectEqualStrings("example.com", h.fields[0].value);
    try testing.expectEqualStrings("Accept", h.fields[1].name);
    try testing.expectEqualStrings("*/*", h.fields[1].value);
    try testing.expectEqualStrings("X-Empty", h.fields[2].name);
    try testing.expectEqualStrings("", h.fields[2].value);
    try testing.expectEqual(Framing.none, h.framing);
    try testing.expect(h.keep_alive);
    try testing.expect(!h.expect_continue);
    try testing.expectEqual(raw.len, h.len);
    // The fields are a prefix of the storage, and point into the input.
    try testing.expectEqual(@as([*]const Field, &storage), h.fields.ptr);
    try testing.expectEqual(raw.ptr + "GET ".len, h.target.ptr);

    try testing.expectEqualStrings("example.com", fieldValue(h.fields, "HOST").?);
    try testing.expectEqualStrings("*/*", fieldValue(h.fields, "accept").?);
    try testing.expectEqual(null, fieldValue(h.fields, "Accept-Language"));
}

test "parseHead: every method of std.http.Method, in its case only" {
    var storage: [4]Field = undefined;
    inline for (@typeInfo(std.http.Method).@"enum".field_names) |name| {
        const target = if (comptime std.mem.eql(u8, name, "OPTIONS")) "*" else "/";
        const h = (try parse(name ++ " " ++ target ++ " HTTP/1.1\r\nHost: a\r\n\r\n", &storage)).?;
        try testing.expectEqualStrings(name, @tagName(h.method));
    }
    try testing.expectError(error.NotImplemented, parse("get / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.NotImplemented, parse("PURGE / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.NotImplemented, parse("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", &storage));
    try testing.expectError(error.BadRequest, parse("GE(T / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.BadRequest, parse(" GET / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.BadRequest, parse("GET\t/ HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
}

test "parseHead: an incomplete head is null, and len counts up to CRLF CRLF" {
    var storage: [100]Field = undefined;
    const raw = "\r\n\r\nPOST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n";
    for (0..raw.len) |n| {
        try testing.expectEqual(null, try parse(raw[0..n], &storage));
    }
    const h = (try parse(raw ++ "hello" ++ "GET / HTTP/1.1\r\n", &storage)).?;
    // Empty lines before the request line count: they are bytes of the head.
    try testing.expectEqual(raw.len, h.len);
    try testing.expectEqual(Framing{ .length = 5 }, h.framing);
    try testing.expectEqualStrings("/a", h.target);
    // A cut CRLF waits for its LF; anything else after the CR is refused.
    try testing.expectEqual(null, try parse("GET / HTTP/1.1\r", &storage));
    try testing.expectError(error.BadRequest, parse("GET / HTTP/1.1\rX", &storage));
    try testing.expectError(error.BadRequest, parse("\nGET / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.BadRequest, parse("\r\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    // An error shows as soon as its byte arrives, before the head ends.
    try testing.expectError(error.BadRequest, parse("GET / HTTP/1.1\r\nHost : a", &storage));
    try testing.expectError(error.VersionNotSupported, parse("GET / HTTP/2", &storage));
    try testing.expectError(error.NotImplemented, parse("BREW ", &storage));
}

test "parseHead: target forms and versions" {
    var storage: [4]Field = undefined;
    const Row = struct { []const u8, ?Version, ?Error };
    const rows = [_]Row{
        .{ "GET /a/b?c=d HTTP/1.1", .http11, null },
        .{ "GET //a HTTP/1.1", .http11, null },
        .{ "GET /a\"b|c{}^`\\[]<>~ HTTP/1.1", .http11, null },
        .{ "GET http://example.com HTTP/1.1", .http11, null },
        .{ "GET http://example.com/a?b HTTP/1.1", .http11, null },
        .{ "GET HTTPS://example.com:8443/ HTTP/1.1", .http11, null },
        .{ "GET http://example.com?a HTTP/1.1", .http11, null },
        .{ "OPTIONS * HTTP/1.1", .http11, null },
        .{ "OPTIONS / HTTP/1.1", .http11, null },
        .{ "GET * HTTP/1.1", null, error.BadRequest },
        .{ "OPTIONS ** HTTP/1.1", null, error.BadRequest },
        .{ "GET http:///a HTTP/1.1", null, error.BadRequest },
        .{ "GET http:// HTTP/1.1", null, error.BadRequest },
        .{ "GET ftp://example.com/ HTTP/1.1", null, error.BadRequest },
        .{ "GET example.com/ HTTP/1.1", null, error.BadRequest },
        .{ "CONNECT example.com:443 HTTP/1.1", null, error.BadRequest },
        .{ "GET a/b HTTP/1.1", null, error.BadRequest },
        .{ "GET  / HTTP/1.1", null, error.BadRequest },
        .{ "GET / HTTP/1.1 ", null, error.BadRequest },
        .{ "GET /a b HTTP/1.1", null, error.BadRequest },
        .{ "GET /\x7f HTTP/1.1", null, error.BadRequest },
        .{ "GET /\x00 HTTP/1.1", null, error.BadRequest },
        .{ "GET /\xc3\xa9 HTTP/1.1", null, error.BadRequest },
        .{ "GET /\t HTTP/1.1", null, error.BadRequest },
        .{ "GET / HTTP/1.0", .http10, null },
        .{ "GET / HTTP/1.2", .http11, null },
        .{ "GET / HTTP/1.9", .http11, null },
        .{ "GET / HTTP/2.0", null, error.VersionNotSupported },
        .{ "GET / HTTP/0.9", null, error.VersionNotSupported },
        .{ "GET / HTTP/9.9", null, error.VersionNotSupported },
        .{ "GET / HTTP/2", null, error.VersionNotSupported },
        .{ "GET / HTTP/3.", null, error.VersionNotSupported },
        .{ "GET / HTTP/1.10", null, error.BadRequest },
        .{ "GET / HTTP/1", null, error.BadRequest },
        .{ "GET / HTTP/11", null, error.BadRequest },
        .{ "GET / HTTP/1.x", null, error.BadRequest },
        .{ "GET / HTTP/a.1", null, error.BadRequest },
        .{ "GET / http/1.1", null, error.BadRequest },
        .{ "GET / HTTP/1.1\n", null, error.BadRequest },
        .{ "GET / RTSP/1.0", null, error.BadRequest },
        .{ "GET /", null, error.BadRequest },
    };
    for (rows) |row| {
        var buffer: [128]u8 = undefined;
        const raw = try std.fmt.bufPrint(&buffer, "{s}\r\nHost: a\r\n\r\n", .{row[0]});
        if (row[2]) |want| {
            testing.expectError(want, parse(raw, &storage)) catch |err| {
                std.debug.print("request line {f}\n", .{std.zig.fmtString(row[0])});
                return err;
            };
        } else {
            const h = (try parse(raw, &storage)).?;
            try testing.expectEqual(row[1].?, h.version);
            try testing.expectEqualStrings(row[0][std.mem.findScalar(u8, row[0], ' ').? + 1 .. std.mem.findScalarLast(u8, row[0], ' ').?], h.target);
        }
    }
}

test "parseHead: limits give 414 and 431 exactly one byte over" {
    const max: Limits = .{};
    var storage: [100]Field = undefined;

    // The target: 8 KiB passes, one byte more is 414, before the line ends.
    const target: [max.max_target_bytes]u8 = @splat('t');
    const at_target_limit = "GET /" ++ target[1..] ++ " HTTP/1.1\r\nHost: a\r\n\r\n";
    try testing.expectEqual(max.max_target_bytes, (try parse(at_target_limit, &storage)).?.target.len);
    try testing.expectError(error.TargetTooLong, parse("GET /" ++ target ++ " HTTP/1.1\r\nHost: a\r\n\r\n", &storage));
    try testing.expectError(error.TargetTooLong, parse("GET /" ++ target, &storage));
    try testing.expectEqual(null, try parse("GET /" ++ target[1..], &storage));

    // The head: 16 KiB passes, one byte more is 431.
    const fixed = "GET / HTTP/1.1\r\nHost: a\r\nX-Fill: \r\n\r\n";
    const fill: [max.max_head_bytes - fixed.len]u8 = @splat('f');
    const at_head_limit = "GET / HTTP/1.1\r\nHost: a\r\nX-Fill: " ++ fill ++ "\r\n\r\n";
    try testing.expectEqual(max.max_head_bytes, at_head_limit.len);
    try testing.expectEqual(at_head_limit.len, (try parse(at_head_limit, &storage)).?.len);
    const over_head_limit = "GET / HTTP/1.1\r\nHost: a\r\nX-Fill: f" ++ fill ++ "\r\n\r\n";
    try testing.expectError(error.HeadTooLarge, parse(over_head_limit, &storage));
    // A head cut at the limit is 431 as soon as the limit is reached; one
    // byte short of it, still null.
    try testing.expectError(error.HeadTooLarge, parse(over_head_limit[0..max.max_head_bytes], &storage));
    try testing.expectEqual(null, try parse(over_head_limit[0 .. max.max_head_bytes - 1], &storage));
    // Empty lines before the request line count too.
    try testing.expectError(error.HeadTooLarge, parse("\r\n" ++ at_head_limit, &storage));

    // The fields: 100 pass, 101 are 431.
    const field = "X-F: 1\r\n";
    const hundred = "GET / HTTP/1.1\r\nHost: a\r\n" ++ comptime repeat(field, 99) ++ "\r\n";
    try testing.expectEqual(100, (try parse(hundred, &storage)).?.fields.len);
    const hundred_and_one = "GET / HTTP/1.1\r\nHost: a\r\n" ++ comptime repeat(field, 100) ++ "\r\n";
    try testing.expectError(error.HeadTooLarge, parse(hundred_and_one, &storage));
    // Less storage lowers the limit.
    try testing.expectError(error.HeadTooLarge, parse(hundred, storage[0..99]));

    // Smaller limits, the same rules.
    const small: Limits = .{ .max_head_bytes = 64, .max_header_fields = 2, .max_target_bytes = 4 };
    try testing.expect(try parseHead("GET /abc HTTP/1.1\r\nHost: a\r\nX: 1\r\n\r\n", small, &storage) != null);
    try testing.expectError(error.TargetTooLong, parseHead("GET /abcd HTTP/1.1\r\n", small, &storage));
    try testing.expectError(error.HeadTooLarge, parseHead("GET / HTTP/1.1\r\nHost: a\r\nX: 1\r\nY: 2\r\n\r\n", small, &storage));

    try testing.expectEqual(400, statusOf(error.BadRequest));
    try testing.expectEqual(414, statusOf(error.TargetTooLong));
    try testing.expectEqual(431, statusOf(error.HeadTooLarge));
    try testing.expectEqual(501, statusOf(error.NotImplemented));
    try testing.expectEqual(505, statusOf(error.VersionNotSupported));
    try testing.expectEqual(417, statusOf(error.ExpectationFailed));
}

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    var out: []const u8 = "";
    for (0..n) |_| out = out ++ s;
    return out;
}

fn expectCases(list: []const cases.Case) !void {
    var storage: [100]Field = undefined;
    for (list) |case| {
        expectCase(case, &storage) catch |err| {
            std.debug.print("case \"{s}\": {f}\n", .{ case.name, std.zig.fmtString(case.raw) });
            return err;
        };
    }
}

fn expectCase(case: cases.Case, storage: []Field) !void {
    const result = parseHead(case.raw, .{}, storage);
    switch (case.expect) {
        .err => |want| try testing.expectError(want, result),
        .head => |want| {
            const h = (try result) orelse return error.TestIncompleteHead;
            try testing.expectEqual(want.method, h.method);
            try testing.expectEqualStrings(want.target, h.target);
            try testing.expectEqual(want.version, h.version);
            try testing.expectEqual(want.framing, h.framing);
            try testing.expectEqual(want.keep_alive, h.keep_alive);
            try testing.expectEqual(want.expect_continue, h.expect_continue);
            try testing.expectEqual(case.raw.len, h.len);
            if (want.fields) |fields| {
                try testing.expectEqual(fields.len, h.fields.len);
                for (fields, h.fields) |field, got| {
                    try testing.expectEqualStrings(field[0], got.name);
                    try testing.expectEqualStrings(field[1], got.value);
                }
            }
        },
    }
}

test "parseHead: every field rule of section 14" {
    try expectCases(&cases.field_rules);
}

test "parseHead: length rules" {
    try expectCases(&cases.length_rules);
}
