//! The wire of the NATS transport: what the headers of a request and of a
//! response carry, the HTTP-style numbers of failures, percent-encoding,
//! and a lenient reader of the `NATS/1.0` block. It follows the NATS
//! Service API (ADR-32), so `nats req` and NATS clients in other languages
//! can call a zefir service and read its failures.
//!
//! A request: `Zefir-Rpc-Version: 1`, `Zefir-Rpc-Request-Id: <32 hex>`,
//! `Content-Type: application/json`, the metadata under its own names, and
//! `Zefir-Rpc-Timeout-Ms: <budget left>`. All are optional for a server: a
//! request from `nats req` has none of them.
//!
//! A success: the body as the payload, the metadata as headers. A failure:
//! `Nats-Service-Error: <message>` and `Nats-Service-Error-Code: <HTTP
//! number>` (required by ADR-32), `Zefir-Rpc-Code`, `Zefir-Rpc-App-Code`,
//! `Zefir-Rpc-Field` when there is one, `Zefir-Rpc-Refused: 1` for a call
//! that did not run, and `Content-Type: application/json` over a body of
//! violations. The message, the app code and the field are percent-encoded
//! like `grpc-message` in gRPC; a client decodes them only when
//! `Zefir-Rpc-Code` is there, so "100% done" from a foreign service stays
//! as it is.
//!
//! NATS headers are case-sensitive (ADR-4): the transport writes and reads
//! its own names exactly as above. Every other name becomes a metadata key
//! in lower case, since clients in Go write `Traceparent`. A response never
//! has a NATS status line: `NATS/1.0 503` is the no responders of the NATS
//! server.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");

const Allocator = std.mem.Allocator;
const Header = Conn.Header;
const Entry = rpc.Metadata.Entry;
const Failure = rpc.Failure;
const Response = rpc.Response;
const Diagnostics = rpc.transport.Diagnostics;

pub const version_header = "Zefir-Rpc-Version";
pub const request_id_header = "Zefir-Rpc-Request-Id";
pub const timeout_header = "Zefir-Rpc-Timeout-Ms";
pub const content_type_header = "Content-Type";
pub const service_error_header = "Nats-Service-Error";
pub const service_error_code_header = "Nats-Service-Error-Code";
pub const code_header = "Zefir-Rpc-Code";
pub const app_code_header = "Zefir-Rpc-App-Code";
pub const field_header = "Zefir-Rpc-Field";
pub const refused_header = "Zefir-Rpc-Refused";

/// The major version of this wire.
pub const version = "1";

/// Whether a header belongs to the transport: `Content-Type` and every
/// `Nats-*` and `Zefir-Rpc-*`, in exactly this case. They never become
/// metadata.
pub fn isTransportHeader(name: []const u8) bool {
    return std.mem.eql(u8, name, content_type_header) or
        std.mem.startsWith(u8, name, "Nats-") or
        std.mem.startsWith(u8, name, "Zefir-Rpc-");
}

/// The number of `Nats-Service-Error-Code` for a code: the HTTP mapping of
/// `google/rpc/code.proto`, the same canonical codes as `core.ErrorCode`.
pub fn statusOf(code: core.ErrorCode) u16 {
    return switch (code) {
        .cancelled => 499,
        .unknown => 500,
        .invalid_argument => 400,
        .deadline_exceeded => 504,
        .not_found => 404,
        .already_exists => 409,
        .permission_denied => 403,
        .resource_exhausted => 429,
        .failed_precondition => 400,
        .aborted => 409,
        .out_of_range => 400,
        .unimplemented => 501,
        .internal => 500,
        .unavailable => 503,
        .data_loss => 500,
        .unauthenticated => 401,
    };
}

fn statusText(code: core.ErrorCode) []const u8 {
    return switch (code) {
        inline else => |c| comptime std.fmt.comptimePrint("{d}", .{statusOf(c)}),
    };
}

/// The code of a failure from a foreign ADR-32 service, which has no
/// `Zefir-Rpc-Code`: by its number.
pub fn codeOfStatus(status: u16) core.ErrorCode {
    return switch (status) {
        400 => .invalid_argument,
        401 => .unauthenticated,
        403 => .permission_denied,
        404 => .not_found,
        409 => .aborted,
        429 => .resource_exhausted,
        499 => .cancelled,
        501 => .unimplemented,
        503 => .unavailable,
        504 => .deadline_exceeded,
        500, 502, 505...599 => .internal,
        else => .unknown,
    };
}

/// The code that `Zefir-Rpc-Code` names; null for a name it does not know.
pub fn codeOfName(name: []const u8) ?core.ErrorCode {
    return std.meta.stringToEnum(core.ErrorCode, name);
}

/// Bytes outside 0x20–0x7E and `%` itself are encoded; so is a space at
/// either end, which a reader of headers would trim.
fn mustEscape(s: []const u8, i: usize) bool {
    const c = s[i];
    return c < 0x20 or c > 0x7e or c == '%' or (c == ' ' and (i == 0 or i == s.len - 1));
}

/// The length of `s` once percent-encoded.
pub fn encodedLen(s: []const u8) usize {
    var n: usize = 0;
    for (0..s.len) |i| n += if (mustEscape(s, i)) 3 else 1;
    return n;
}

/// `s` percent-encoded into `out`, which holds `encodedLen(s)` bytes.
pub fn encode(out: []u8, s: []const u8) []u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (mustEscape(s, i)) {
            out[n..][0..3].* = .{ '%', hex[c >> 4], hex[c & 15] };
            n += 3;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

/// `s` percent-decoded into `out`, which holds `s.len` bytes. Lenient: a
/// `%` without two hex digits after it stays as it is.
pub fn decode(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                out[n] = (hi.? << 4) | lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// A `NATS/1.0` block as it came, read leniently, as zefir-nats reads it:
/// the server forwards a publisher's block without checking it. A line
/// without a colon is skipped, a block without the version line is read
/// from its first line, a status comes only from a well-formed
/// `NATS/1.0 <code>` line, and lines may end in CRLF or LF.
pub const Block = struct {
    bytes: []const u8,

    const version_line = "NATS/1.0";

    /// The status on the first line, such as 503 for no responders; null
    /// when there is none.
    pub fn status(b: Block) ?u16 {
        const rest = b.afterVersion() orelse return null;
        if (rest.len < 3) return null;
        var code: u16 = 0;
        for (rest[0..3]) |c| {
            if (!std.ascii.isDigit(c)) return null;
            code = code * 10 + (c - '0');
        }
        if (rest.len > 3 and rest[3] != ' ' and rest[3] != '\t') return null;
        return code;
    }

    /// The headers in wire order.
    pub fn fields(b: Block) FieldIterator {
        var it: FieldIterator = .{ .rest = b.bytes };
        if (std.mem.startsWith(u8, b.bytes, version_line)) _ = it.nextLine();
        return it;
    }

    /// The first line after `NATS/1.0` and its whitespace; null when the
    /// block does not start with a version line.
    fn afterVersion(b: Block) ?[]const u8 {
        var it: FieldIterator = .{ .rest = b.bytes };
        const first = it.nextLine() orelse return null;
        if (!std.mem.startsWith(u8, first, version_line)) return null;
        const rest = first[version_line.len..];
        if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
        return std.mem.trimStart(u8, rest, " \t");
    }
};

/// One header as it came; the value without whitespace at its ends.
pub const Field = struct { name: []const u8, value: []const u8 };

pub const FieldIterator = struct {
    rest: []const u8,

    pub fn next(it: *FieldIterator) ?Field {
        while (it.nextLine()) |line| {
            // The blank line ends the block.
            if (line.len == 0) {
                it.rest = "";
                return null;
            }
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (colon == 0) continue;
            return .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
        }
        return null;
    }

    /// The next line without its CRLF or LF; null at the end.
    fn nextLine(it: *FieldIterator) ?[]const u8 {
        if (it.rest.len == 0) return null;
        const end = std.mem.findScalar(u8, it.rest, '\n') orelse it.rest.len;
        var result = it.rest[0..end];
        it.rest = if (end < it.rest.len) it.rest[end + 1 ..] else "";
        if (result.len > 0 and result[result.len - 1] == '\r') result = result[0 .. result.len - 1];
        return result;
    }
};

/// The longest codec the transport carries in `Content-Type`.
pub const max_codec_bytes = 64;

const media_head = "application/";

/// The text that the headers of a request point to; it lives as long as
/// they do.
pub const RequestText = struct {
    request_id: [32]u8 = undefined,
    content_type: [media_head.len + max_codec_bytes]u8 = undefined,
    content_type_len: usize = 0,
    timeout: [20]u8 = undefined,
    timeout_len: usize = 0,
};

/// How many headers a request with `metadata_len` entries of metadata has.
pub fn requestHeaderCount(metadata_len: usize) usize {
    return metadata_len + 4;
}

/// The headers of a request in `out`, which holds `requestHeaderCount`
/// of them: the version, the request id and the content type, the
/// metadata as it is, and last the budget left in milliseconds, measured
/// right before publish. Null for a codec that cannot be a media subtype:
/// `application/<codec>` carries it.
pub fn requestHeaders(
    out: []Header,
    text: *RequestText,
    request_id: [16]u8,
    codec: []const u8,
    timeout_ms: u64,
    metadata: []const Entry,
) ?[]Header {
    if (!isCodec(codec)) return null;
    text.request_id = std.fmt.bytesToHex(request_id, .lower);
    @memcpy(text.content_type[0..media_head.len], media_head);
    @memcpy(text.content_type[media_head.len..][0..codec.len], codec);
    text.content_type_len = media_head.len + codec.len;
    text.timeout_len = (std.fmt.bufPrint(&text.timeout, "{d}", .{timeout_ms}) catch unreachable).len;
    out[0] = .{ .name = version_header, .value = version };
    out[1] = .{ .name = request_id_header, .value = &text.request_id };
    out[2] = .{ .name = content_type_header, .value = text.content_type[0..text.content_type_len] };
    for (metadata, out[3..][0..metadata.len]) |entry, *header| header.* = .{ .name = entry.key, .value = entry.value };
    out[3 + metadata.len] = .{ .name = timeout_header, .value = text.timeout[0..text.timeout_len] };
    return out[0..requestHeaderCount(metadata.len)];
}

fn isCodec(codec: []const u8) bool {
    if (codec.len == 0 or codec.len > max_codec_bytes) return false;
    for (codec) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '+', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Refusals for a request whose transport headers are broken; the
/// transport answers them itself, as the engine answers its own.
pub const refusals = struct {
    pub const invalid_version: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid Zefir-Rpc-Version header" };
    pub const unsupported_version: Failure = .{ .code = .unimplemented, .app_code = "rpc.unsupported_version", .message = "Unsupported Zefir-Rpc-Version" };
    pub const invalid_request_id: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid Zefir-Rpc-Request-Id header" };
    pub const invalid_timeout: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid Zefir-Rpc-Timeout-Ms header" };
    pub const repeated_version: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Repeated Zefir-Rpc-Version header" };
    pub const repeated_request_id: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Repeated Zefir-Rpc-Request-Id header" };
    pub const repeated_timeout: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Repeated Zefir-Rpc-Timeout-Ms header" };
    pub const repeated_content_type: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Repeated Content-Type header" };
};

/// What the headers of a request tell its head.
pub const RequestFields = struct {
    /// Null when the request has none: the server makes one up.
    request_id: ?[16]u8 = null,
    /// Null when the request has none: the server's default applies.
    timeout: ?std.Io.Duration = null,
    /// "json" for `application/json` and for a request without
    /// `Content-Type`; the engine refuses another codec.
    codec: []const u8 = "json",
    /// In wire order; the slices point into the block and `Scratch`.
    metadata: []const Entry = &.{},
};

/// Room for the metadata of one request, kept by a receiving task from
/// request to request, so that no request costs an allocation.
pub const Scratch = struct {
    /// One more entry than the server's `max_metadata_entries`: the
    /// metadata of a request with more is cut there, and the engine
    /// refuses it as too much without the transport holding the rest.
    entries: []Entry,
    /// Names with capital letters become keys in lower case here. Once it
    /// is full the names keep their case: then the keys alone are more
    /// than `max_metadata_bytes`, and the engine refuses the metadata for
    /// its size before it looks at a key.
    keys: []u8,
};

pub const ParsedRequest = union(enum) {
    request: RequestFields,
    /// A transport header is broken or repeated, or the version is not 1:
    /// the transport refuses the call itself.
    refused: Failure,
};

/// Reads the headers of a request. Transport headers it does not know,
/// such as a later `Zefir-Rpc-*`, are skipped.
pub fn parseRequest(block_bytes: []const u8, scratch: Scratch) ParsedRequest {
    const Seen = struct {
        value: ?[]const u8 = null,
        repeated: bool = false,

        fn take(s: *@This(), value: []const u8) void {
            if (s.value == null) s.value = value else s.repeated = true;
        }
    };
    var version_seen: Seen = .{};
    var request_id: Seen = .{};
    var timeout: Seen = .{};
    var content_type: Seen = .{};
    var count: usize = 0;
    var keys_used: usize = 0;
    var it = (Block{ .bytes = block_bytes }).fields();
    while (it.next()) |field| {
        if (isTransportHeader(field.name)) {
            if (std.mem.eql(u8, field.name, version_header)) {
                version_seen.take(field.value);
            } else if (std.mem.eql(u8, field.name, request_id_header)) {
                request_id.take(field.value);
            } else if (std.mem.eql(u8, field.name, timeout_header)) {
                timeout.take(field.value);
            } else if (std.mem.eql(u8, field.name, content_type_header)) {
                content_type.take(field.value);
            }
            continue;
        }
        if (count == scratch.entries.len) continue;
        scratch.entries[count] = .{ .key = lowerKey(field.name, scratch.keys, &keys_used), .value = field.value };
        count += 1;
    }

    // The version first: a request of another major version may mean the
    // rest differently.
    if (version_seen.repeated) return .{ .refused = refusals.repeated_version };
    if (version_seen.value) |value| {
        const major = majorVersion(value) orelse return .{ .refused = refusals.invalid_version };
        if (major != 1) return .{ .refused = refusals.unsupported_version };
    }
    if (request_id.repeated) return .{ .refused = refusals.repeated_request_id };
    if (timeout.repeated) return .{ .refused = refusals.repeated_timeout };
    if (content_type.repeated) return .{ .refused = refusals.repeated_content_type };
    var fields: RequestFields = .{ .metadata = scratch.entries[0..count] };
    if (request_id.value) |hex| {
        var id: [16]u8 = undefined;
        if (hex.len != 32) return .{ .refused = refusals.invalid_request_id };
        _ = std.fmt.hexToBytes(&id, hex) catch return .{ .refused = refusals.invalid_request_id };
        fields.request_id = id;
    }
    if (timeout.value) |ms| fields.timeout = parseTimeout(ms) orelse return .{ .refused = refusals.invalid_timeout };
    if (content_type.value) |value| fields.codec = codecOf(value);
    return .{ .request = fields };
}

/// `name` in lower case: itself when it has no capital letter, a copy in
/// `keys` while there is room, else itself.
fn lowerKey(name: []const u8, keys: []u8, used: *usize) []const u8 {
    for (name) |c| {
        if (std.ascii.isUpper(c)) break;
    } else return name;
    if (keys.len - used.* < name.len) return name;
    const key = std.ascii.lowerString(keys[used.*..][0..name.len], name);
    used.* += name.len;
    return key;
}

/// The major version of `Zefir-Rpc-Version`: the digits before an
/// optional dot, such as 1 in "1" and "1.2".
fn majorVersion(value: []const u8) ?u32 {
    const end = std.mem.findScalar(u8, value, '.') orelse value.len;
    const digits = value[0..end];
    if (digits.len == 0 or digits.len > 9) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(u32, digits, 10) catch null;
}

/// `Zefir-Rpc-Timeout-Ms`: decimal milliseconds, nothing else.
fn parseTimeout(value: []const u8) ?std.Io.Duration {
    if (value.len == 0 or value.len > 20) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    const ms = std.fmt.parseUnsigned(u64, value, 10) catch return null;
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

/// The codec of a `Content-Type`: "json" for `application/json` with or
/// without parameters, `x` for `application/x`, else the media type itself,
/// which the engine refuses.
fn codecOf(value: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return "json";
    if (std.ascii.startsWithIgnoreCase(media, media_head) and media.len > media_head.len) return media[media_head.len..];
    return media;
}

/// The headers of a response and the text they point to, both from one
/// allocator.
pub const ResponseHeaders = struct {
    headers: []Header,
    text: []u8,

    pub fn deinit(h: ResponseHeaders, a: Allocator) void {
        a.free(h.text);
        a.free(h.headers);
    }
};

/// The headers of `response`: those of a failure, then its metadata as it
/// is. A success has only its metadata.
pub fn responseHeaders(a: Allocator, response: *const Response) error{OutOfMemory}!ResponseHeaders {
    const failure: ?Failure = switch (response.status) {
        .ok => null,
        .failure => |f| f,
    };
    var count = response.metadata.len;
    var text_len: usize = 0;
    if (failure) |f| {
        count += 4;
        if (f.field != null) count += 1;
        if (response.refused) count += 1;
        if (response.body.len > 0) count += 1;
        text_len = encodedLen(f.message) + encodedLen(f.app_code) + if (f.field) |field| encodedLen(field) else 0;
    }
    const headers = try a.alloc(Header, count);
    errdefer a.free(headers);
    const text = try a.alloc(u8, text_len);
    var n: usize = 0;
    if (failure) |f| {
        var t: usize = 0;
        const message = encode(text[t..], f.message);
        t += message.len;
        const app_code = encode(text[t..], f.app_code);
        t += app_code.len;
        headers[0] = .{ .name = service_error_header, .value = message };
        headers[1] = .{ .name = service_error_code_header, .value = statusText(f.code) };
        headers[2] = .{ .name = code_header, .value = @tagName(f.code) };
        headers[3] = .{ .name = app_code_header, .value = app_code };
        n = 4;
        if (f.field) |field| {
            headers[n] = .{ .name = field_header, .value = encode(text[t..], field) };
            n += 1;
        }
        if (response.refused) {
            headers[n] = .{ .name = refused_header, .value = "1" };
            n += 1;
        }
        if (response.body.len > 0) {
            headers[n] = .{ .name = content_type_header, .value = media_head ++ "json" };
            n += 1;
        }
    }
    for (response.metadata, headers[n..]) |entry, *header| header.* = .{ .name = entry.key, .value = entry.value };
    return .{ .headers = headers, .text = text };
}

/// The limits a caller sets on a response.
pub const ResponseLimits = struct {
    max_body_bytes: usize,
    max_metadata_entries: u32,
    max_metadata_bytes: u32,
};

pub const ParseResponseError = error{
    /// `NATS/1.0 503` without a payload: no responders.
    Unavailable,
    /// Any other NATS status.
    ProtocolViolation,
    /// Over the caller's limits.
    ResponseTooLarge,
    OutOfMemory,
};

/// The response of a call, from the block and the payload of its reply, in
/// memory from `a` (two blocks: the metadata entries, and all the text).
/// The limits are checked before anything is allocated; the message, the
/// app code and the field of a failure count toward `max_metadata_bytes`
/// by their length on the wire.
pub fn parseResponse(
    a: Allocator,
    block_bytes: []const u8,
    payload: []const u8,
    limits: ResponseLimits,
    diagnostics: ?*Diagnostics,
) ParseResponseError!Response {
    const block: Block = .{ .bytes = block_bytes };
    if (block.status()) |status| {
        if (status == 503 and payload.len == 0) {
            if (diagnostics) |d| d.set(.receive, null, "no responders: no server serves the subject of the call", .{});
            return error.Unavailable;
        }
        if (diagnostics) |d| d.set(.receive, null, "a reply with the NATS status {d} and {d} bytes of payload", .{ status, payload.len });
        return error.ProtocolViolation;
    }
    if (payload.len > limits.max_body_bytes) {
        if (diagnostics) |d| d.set(.receive, null, "response body of {d} bytes is over max_response_bytes {d}", .{ payload.len, limits.max_body_bytes });
        return error.ResponseTooLarge;
    }

    var found: Found = .{};
    var entries: usize = 0;
    // As rpc.transport.metadataBytes counts.
    var metadata_bytes: usize = 2;
    var text_len: usize = payload.len;
    var it = block.fields();
    while (it.next()) |field| {
        if (isTransportHeader(field.name)) {
            found.take(field);
            continue;
        }
        entries += 1;
        metadata_bytes += 3 + field.name.len + field.value.len;
        text_len += field.name.len + field.value.len;
    }
    const is_failure = found.service_error != null or found.service_error_code != null;
    // The strings of a failure are copied too, so they count with the
    // metadata: else a foreign reply could take up to max_payload.
    const strings_len = if (is_failure) lengthOf(found.service_error) + lengthOf(found.app_code) + lengthOf(found.field) else 0;
    if (entries > limits.max_metadata_entries or metadata_bytes + strings_len > limits.max_metadata_bytes) {
        if (diagnostics) |d| d.set(.receive, null, "response metadata of {d} entries and {d} bytes, {d} of them the strings of a failure, is over the limits of {d} and {d}", .{
            entries, metadata_bytes + strings_len, strings_len, limits.max_metadata_entries, limits.max_metadata_bytes,
        });
        return error.ResponseTooLarge;
    }
    text_len += strings_len;

    const metadata = try a.alloc(Entry, entries);
    errdefer a.free(metadata);
    const text = try a.alloc(u8, text_len);
    var t: usize = 0;
    it = block.fields();
    var i: usize = 0;
    while (it.next()) |field| {
        if (isTransportHeader(field.name)) continue;
        const key = std.ascii.lowerString(text[t..][0..field.name.len], field.name);
        t += key.len;
        const value = text[t..][0..field.value.len];
        @memcpy(value, field.value);
        t += value.len;
        metadata[i] = .{ .key = key, .value = value };
        i += 1;
    }
    const body = text[t..][0..payload.len];
    @memcpy(body, payload);
    t += body.len;
    if (!is_failure) return .{ .status = .ok, .metadata = metadata, .body = body };

    // Strings are decoded only from a zefir server: a foreign one may write
    // "100% done".
    const decoding = found.code != null;
    const strings = struct {
        fn take(out: []u8, at: *usize, raw: []const u8, decoded: bool) []const u8 {
            const s = if (decoded) decode(out[at.*..], raw) else blk: {
                @memcpy(out[at.*..][0..raw.len], raw);
                break :blk out[at.*..][0..raw.len];
            };
            at.* += s.len;
            return s;
        }
    };
    const message = strings.take(text, &t, found.service_error orelse "", decoding);
    const app_code = strings.take(text, &t, found.app_code orelse "", decoding);
    const field: ?[]const u8 = if (found.field) |raw| strings.take(text, &t, raw, decoding) else null;
    const code = codeOfFailure(found);
    const refused = if (found.refused) |value| std.mem.eql(u8, value, "1") else false;
    return .{
        .status = .{ .failure = .{ .code = code, .app_code = app_code, .message = message, .field = field } },
        .metadata = metadata,
        .body = body,
        .refused = refused,
    };
}

/// The transport headers of a response; the first of each counts.
const Found = struct {
    service_error: ?[]const u8 = null,
    service_error_code: ?[]const u8 = null,
    code: ?[]const u8 = null,
    app_code: ?[]const u8 = null,
    field: ?[]const u8 = null,
    refused: ?[]const u8 = null,

    fn take(f: *Found, field: Field) void {
        const slot: *?[]const u8 = if (std.mem.eql(u8, field.name, service_error_header))
            &f.service_error
        else if (std.mem.eql(u8, field.name, service_error_code_header))
            &f.service_error_code
        else if (std.mem.eql(u8, field.name, code_header))
            &f.code
        else if (std.mem.eql(u8, field.name, app_code_header))
            &f.app_code
        else if (std.mem.eql(u8, field.name, field_header))
            &f.field
        else if (std.mem.eql(u8, field.name, refused_header))
            &f.refused
        else
            return;
        if (slot.* == null) slot.* = field.value;
    }
};

fn lengthOf(s: ?[]const u8) usize {
    return if (s) |value| value.len else 0;
}

/// `Zefir-Rpc-Code` when it names a code, else the number of
/// `Nats-Service-Error-Code`, else `unknown`.
fn codeOfFailure(found: Found) core.ErrorCode {
    if (found.code) |name| {
        if (codeOfName(name)) |code| return code;
    }
    const number = found.service_error_code orelse return .unknown;
    if (number.len == 0 or number.len > 5) return .unknown;
    for (number) |c| if (!std.ascii.isDigit(c)) return .unknown;
    return codeOfStatus(std.fmt.parseUnsigned(u16, number, 10) catch return .unknown);
}

const testing = std.testing;

test "every code has a number, and the number of a foreign service maps back" {
    const expected = [_]struct { core.ErrorCode, u16, core.ErrorCode }{
        .{ .cancelled, 499, .cancelled },
        .{ .unknown, 500, .internal },
        .{ .invalid_argument, 400, .invalid_argument },
        .{ .deadline_exceeded, 504, .deadline_exceeded },
        .{ .not_found, 404, .not_found },
        .{ .already_exists, 409, .aborted },
        .{ .permission_denied, 403, .permission_denied },
        .{ .resource_exhausted, 429, .resource_exhausted },
        .{ .failed_precondition, 400, .invalid_argument },
        .{ .aborted, 409, .aborted },
        .{ .out_of_range, 400, .invalid_argument },
        .{ .unimplemented, 501, .unimplemented },
        .{ .internal, 500, .internal },
        .{ .unavailable, 503, .unavailable },
        .{ .data_loss, 500, .internal },
        .{ .unauthenticated, 401, .unauthenticated },
    };
    try testing.expectEqual(std.enums.values(core.ErrorCode).len, expected.len);
    for (expected) |row| {
        const code, const status, const back = row;
        try testing.expectEqual(status, statusOf(code));
        var text: [3]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&text, "{d}", .{status}), statusText(code));
        try testing.expectEqual(back, codeOfStatus(status));
        try testing.expectEqual(code, codeOfName(@tagName(code)).?);
    }
    for ([_]u16{ 502, 505, 599 }) |status| try testing.expectEqual(core.ErrorCode.internal, codeOfStatus(status));
    for ([_]u16{ 0, 200, 302, 402, 408, 418, 600, 999 }) |status| try testing.expectEqual(core.ErrorCode.unknown, codeOfStatus(status));
    try testing.expectEqual(@as(?core.ErrorCode, null), codeOfName("NotFound"));
    try testing.expectEqual(@as(?core.ErrorCode, null), codeOfName(""));
}

test "percent-encoding: bytes outside 0x20-0x7E, the percent sign and spaces at the ends" {
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "User not found", "User not found" },
        .{ "100% done", "100%25 done" },
        .{ "line\r\nInjected: yes", "line%0D%0AInjected: yes" },
        .{ "tab\there", "tab%09here" },
        .{ "Привет", "%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82" },
        .{ "del\x7f", "del%7F" },
        .{ " padded ", "%20padded%20" },
        .{ " ", "%20" },
        .{ "", "" },
        .{ "items[2].name", "items[2].name" },
    }) |case| {
        const plain, const wire = case;
        var out: [64]u8 = undefined;
        try testing.expectEqual(wire.len, encodedLen(plain));
        try testing.expectEqualStrings(wire, encode(&out, plain));
        var back: [64]u8 = undefined;
        try testing.expectEqualStrings(plain, decode(&back, wire));
    }
}

test "percent-decoding is lenient: a broken sequence stays as it is" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "100%", "100%" },
        .{ "100% done", "100% done" },
        .{ "%zz%4", "%zz%4" },
        .{ "%4", "%4" },
        .{ "%%41", "%A" },
        .{ "%41%61%2a", "Aa*" },
        .{ "a%2", "a%2" },
    }) |case| {
        var out: [16]u8 = undefined;
        try testing.expectEqualStrings(case[1], decode(&out, case[0]));
    }
}

test "the block reader: status line, fields in order, leniency" {
    const plain: Block = .{ .bytes = "NATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nEmpty:\r\nSpaced:  v  \r\n\r\n" };
    try testing.expectEqual(@as(?u16, null), plain.status());
    var it = plain.fields();
    const expected = [_]Field{ .{ .name = "X-Multi", .value = "one" }, .{ .name = "X-Multi", .value = "two" }, .{ .name = "Empty", .value = "" }, .{ .name = "Spaced", .value = "v" } };
    for (expected) |want| {
        const got = it.next().?;
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
    try testing.expect(it.next() == null);

    try testing.expectEqual(@as(?u16, 503), (Block{ .bytes = "NATS/1.0 503\r\n\r\n" }).status());
    try testing.expectEqual(@as(?u16, 408), (Block{ .bytes = "NATS/1.0  408   Request Timeout\r\nNats-Pending-Messages: 1\r\n\r\n" }).status());
    for ([_][]const u8{ "", "NATS/1.0 5\r\n\r\n", "NATS/1.0 50x\r\n\r\n", "NATS/1.00\r\n\r\n", "NATS/1.0 5030\r\n\r\n", "HTTP/1.1 503\r\n\r\n", "garbage" }) |bytes| {
        try testing.expectEqual(@as(?u16, null), (Block{ .bytes = bytes }).status());
    }

    // Lines without a colon or a name are skipped, LF alone ends a line,
    // the blank line ends the block, a block may lack the version line.
    var loose = (Block{ .bytes = "NATS/1.0\nno colon\n: no name\nGood:  yes \nAfter: x\n\nIgnored: z\n" }).fields();
    try testing.expectEqualStrings("yes", loose.next().?.value);
    try testing.expectEqualStrings("After", loose.next().?.name);
    try testing.expect(loose.next() == null);
    var bare = (Block{ .bytes = "X-Id: 1\r\nY: 2\r\n\r\n" }).fields();
    try testing.expectEqualStrings("X-Id", bare.next().?.name);
    try testing.expectEqualStrings("2", bare.next().?.value);
    try testing.expect(bare.next() == null);
    var none = (Block{ .bytes = "" }).fields();
    try testing.expect(none.next() == null);
}

test "transport headers by their exact names; the rest is metadata" {
    for ([_][]const u8{ "Content-Type", "Nats-Service-Error", "Nats-Msg-Id", "Zefir-Rpc-Version", "Zefir-Rpc-Something-Later" }) |name| {
        try testing.expect(isTransportHeader(name));
    }
    for ([_][]const u8{ "content-type", "nats-service-error", "zefir-rpc-version", "Traceparent", "authorization", "zefir-correlation-id", "X-Nats" }) |name| {
        try testing.expect(!isTransportHeader(name));
    }
}

fn testScratch(entries: []Entry, keys: []u8) Scratch {
    return .{ .entries = entries, .keys = keys };
}

test "a request from a zefir client: every header in its place" {
    var buffer: [8]Header = undefined;
    var text: RequestText = .{};
    const id: [16]u8 = .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0xff };
    const metadata = [_]Entry{ .{ .key = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }, .{ .key = "x-a", .value = "" } };
    const headers = requestHeaders(&buffer, &text, id, "json", 2999, &metadata).?;
    const expected = [_]Header{
        .{ .name = "Zefir-Rpc-Version", .value = "1" },
        .{ .name = "Zefir-Rpc-Request-Id", .value = "000102030405060708090a0b0c0d0eff" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ .name = "x-a", .value = "" },
        .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "2999" },
    };
    try testing.expectEqual(expected.len, headers.len);
    for (expected, headers) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }
    try testing.expect(requestHeaders(&buffer, &text, id, "x/y", 1, &.{}) == null);
    try testing.expect(requestHeaders(&buffer, &text, id, "", 1, &.{}) == null);
    try testing.expectEqualStrings("application/msgpack", requestHeaders(&buffer, &text, id, "msgpack", 1, &.{}).?[2].value);
}

/// The headers of `headers` as the block a NATS library writes.
fn blockOf(out: []u8, headers: []const Header) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("NATS/1.0\r\n") catch unreachable;
    for (headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
    return w.buffered();
}

test "a request round trip: the server reads what the client wrote" {
    var buffer: [8]Header = undefined;
    var text: RequestText = .{};
    const id: [16]u8 = @splat(0xab);
    const metadata = [_]Entry{ .{ .key = "authorization", .value = "Bearer t" }, .{ .key = "x-b", .value = "2" }, .{ .key = "x-a", .value = "" }, .{ .key = "x-b", .value = "3" } };
    const headers = requestHeaders(&buffer, &text, id, "json", 1500, &metadata).?;
    var block_buffer: [512]u8 = undefined;
    const block = blockOf(&block_buffer, headers);
    var entries: [65]Entry = undefined;
    var keys: [1024]u8 = undefined;
    const fields = switch (parseRequest(block, testScratch(&entries, &keys))) {
        .request => |r| r,
        .refused => return error.TestUnexpectedRefusal,
    };
    try testing.expectEqualSlices(u8, &id, &fields.request_id.?);
    try testing.expectEqual(@as(i96, 1500 * std.time.ns_per_ms), fields.timeout.?.nanoseconds);
    try testing.expectEqualStrings("json", fields.codec);
    try testing.expectEqual(metadata.len, fields.metadata.len);
    for (metadata, fields.metadata) |want, got| {
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqualStrings(want.value, got.value);
    }
}

test "a request as nats req sends it: no zefir headers, names in any case" {
    var entries: [65]Entry = undefined;
    var keys: [1024]u8 = undefined;
    const bare = parseRequest("", testScratch(&entries, &keys)).request;
    try testing.expectEqual(@as(?[16]u8, null), bare.request_id);
    try testing.expectEqual(@as(?std.Io.Duration, null), bare.timeout);
    try testing.expectEqualStrings("json", bare.codec);
    try testing.expectEqual(@as(usize, 0), bare.metadata.len);

    const go = parseRequest("NATS/1.0\r\nTraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nX-Tenant-ID: acme\r\nNats-Msg-Id: 7\r\nZefir-Rpc-Later: x\r\n\r\n", testScratch(&entries, &keys)).request;
    try testing.expectEqual(@as(usize, 2), go.metadata.len);
    try testing.expectEqualStrings("traceparent", go.metadata[0].key);
    try testing.expectEqualStrings("x-tenant-id", go.metadata[1].key);
    try testing.expectEqualStrings("acme", go.metadata[1].value);
}

test "broken, repeated and later transport headers of a request are refused" {
    var entries: [65]Entry = undefined;
    var keys: [1024]u8 = undefined;
    const Case = struct { []const u8, Failure };
    const r = refusals;
    for ([_]Case{
        .{ "Zefir-Rpc-Version: 2\r\n", r.unsupported_version },
        .{ "Zefir-Rpc-Version: 2.0\r\n", r.unsupported_version },
        .{ "Zefir-Rpc-Version: one\r\n", r.invalid_version },
        .{ "Zefir-Rpc-Version: \r\n", r.invalid_version },
        .{ "Zefir-Rpc-Version: 1\r\nZefir-Rpc-Version: 1\r\n", r.repeated_version },
        .{ "Zefir-Rpc-Request-Id: abc\r\n", r.invalid_request_id },
        .{ "Zefir-Rpc-Request-Id: 0123456789abcdef0123456789abcdeg\r\n", r.invalid_request_id },
        .{ "Zefir-Rpc-Request-Id: 0123456789abcdef0123456789abcdef\r\nZefir-Rpc-Request-Id: 0123456789abcdef0123456789abcdef\r\n", r.repeated_request_id },
        .{ "Zefir-Rpc-Timeout-Ms: soon\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: -5\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: +5\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: 1_000\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: 1.5\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: \r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: 18446744073709551616\r\n", r.invalid_timeout },
        .{ "Zefir-Rpc-Timeout-Ms: 100\r\nZefir-Rpc-Timeout-Ms: 100\r\n", r.repeated_timeout },
        .{ "Content-Type: application/json\r\nContent-Type: application/json\r\n", r.repeated_content_type },
        // The version comes first.
        .{ "Zefir-Rpc-Timeout-Ms: soon\r\nZefir-Rpc-Version: 2\r\n", r.unsupported_version },
    }) |case| {
        const headers, const expected = case;
        var block: [256]u8 = undefined;
        const bytes = std.fmt.bufPrint(&block, "NATS/1.0\r\n{s}\r\n", .{headers}) catch unreachable;
        switch (parseRequest(bytes, testScratch(&entries, &keys))) {
            .request => return error.TestExpectedRefusal,
            .refused => |f| try testing.expectEqualStrings(expected.message, f.message),
        }
    }
    // What is right passes: upper-case hex, "1.4", the largest budget,
    // a zero budget (the engine refuses it as deadline_exceeded).
    const fine = parseRequest("NATS/1.0\r\nZefir-Rpc-Version: 1.4\r\nZefir-Rpc-Request-Id: 0123456789ABCDEF0123456789abcdef\r\nZefir-Rpc-Timeout-Ms: 18446744073709551615\r\n\r\n", testScratch(&entries, &keys)).request;
    try testing.expectEqual(@as(u8, 0xef), fine.request_id.?[15]);
    try testing.expectEqual(@as(i96, std.math.maxInt(u64)) * std.time.ns_per_ms, fine.timeout.?.nanoseconds);
    try testing.expectEqual(@as(i96, 0), parseRequest("Zefir-Rpc-Timeout-Ms: 0\r\n", testScratch(&entries, &keys)).request.timeout.?.nanoseconds);
}

test "the codec of a request comes from Content-Type" {
    var entries: [4]Entry = undefined;
    var keys: [64]u8 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ "application/json", "json" },
        .{ "Application/JSON; charset=utf-8", "json" },
        .{ "application/msgpack", "msgpack" },
        .{ "text/plain", "text/plain" },
        .{ "application/", "application/" },
    }) |case| {
        var block: [128]u8 = undefined;
        const bytes = std.fmt.bufPrint(&block, "Content-Type: {s}\r\n\r\n", .{case[0]}) catch unreachable;
        try testing.expectEqualStrings(case[1], parseRequest(bytes, testScratch(&entries, &keys)).request.codec);
    }
}

test "too much metadata is cut at one entry over the limit, and nothing is allocated" {
    // 10 000 headers in a block of over 64 KiB, a server that takes 64.
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try block.writer.writeAll("NATS/1.0\r\n");
    for (0..10_000) |i| try block.writer.print("X-Many-{d}: {d}\r\n", .{ i, i });
    try block.writer.writeAll("Zefir-Rpc-Version: 1\r\n\r\n");
    try testing.expect(block.written().len > 64 * 1024);
    var entries: [65]Entry = undefined;
    var keys: [16 * 1024]u8 = undefined;
    const fields = parseRequest(block.written(), testScratch(&entries, &keys)).request;
    try testing.expectEqual(@as(usize, 65), fields.metadata.len);
    try testing.expectEqualStrings("x-many-64", fields.metadata[64].key);

    // Keys with capital letters beyond the room for keys keep their case
    // and their length: the engine counts them as more than its limit.
    var small_keys: [8]u8 = undefined;
    const kept = parseRequest("Long-Name-A: 1\r\nshort: 2\r\nLong-Name-B: 3\r\n", testScratch(&entries, &small_keys)).request;
    try testing.expectEqualStrings("Long-Name-A", kept.metadata[0].key);
    try testing.expectEqualStrings("short", kept.metadata[1].key);
    try testing.expectEqualStrings("Long-Name-B", kept.metadata[2].key);
    const lowered = parseRequest("AB: 1\r\nCD: 2\r\nEFGHIJ: 3\r\n", testScratch(&entries, &small_keys)).request;
    try testing.expectEqualStrings("ab", lowered.metadata[0].key);
    try testing.expectEqualStrings("cd", lowered.metadata[1].key);
    try testing.expectEqualStrings("EFGHIJ", lowered.metadata[2].key);
}

const default_limits: ResponseLimits = .{ .max_body_bytes = 1 << 20, .max_metadata_entries = 64, .max_metadata_bytes = 16 * 1024 };

/// A response through its headers and a NATS block, read back in an arena.
fn roundTrip(arena: Allocator, response: *const Response) !Response {
    const owned = try responseHeaders(testing.allocator, response);
    defer owned.deinit(testing.allocator);
    const block = try arena.alloc(u8, 4096);
    return parseResponse(arena, if (owned.headers.len == 0) "" else blockOf(block, owned.headers), response.body, default_limits, null);
}

test "a success: the body as the payload, the metadata as headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const metadata = [_]Entry{ .{ .key = "x-z", .value = "last" }, .{ .key = "x-y", .value = "" }, .{ .key = "x-z", .value = "first" } };
    const sent: Response = .{ .status = .ok, .metadata = &metadata, .body = "{\"id\":\"1\"}" };
    const owned = try responseHeaders(testing.allocator, &sent);
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(metadata.len, owned.headers.len);
    const got = try roundTrip(arena.allocator(), &sent);
    try testing.expect(got.status == .ok);
    try testing.expectEqualStrings(sent.body, got.body);
    try testing.expectEqual(metadata.len, got.metadata.len);
    for (metadata, got.metadata) |want, entry| {
        try testing.expectEqualStrings(want.key, entry.key);
        try testing.expectEqualStrings(want.value, entry.value);
    }
    // No headers at all.
    const bare = try roundTrip(arena.allocator(), &.{ .status = .ok, .body = "" });
    try testing.expect(bare.status == .ok);
    try testing.expectEqual(@as(usize, 0), bare.metadata.len);
    try testing.expectEqualStrings("", bare.body);
}

test "a failure: ADR-32 headers, zefir headers, encoded strings, refused" {
    const sent: Response = .{
        .status = .{ .failure = .{ .code = .not_found, .app_code = "users.100%", .message = "User\r\nnot found: 100% sure ", .field = "items[2].имя" } },
        .metadata = &.{.{ .key = "x-trace", .value = "t" }},
        .body = "{\"violations\":[]}",
        .refused = true,
    };
    const owned = try responseHeaders(testing.allocator, &sent);
    defer owned.deinit(testing.allocator);
    const expected = [_]Header{
        .{ .name = "Nats-Service-Error", .value = "User%0D%0Anot found: 100%25 sure%20" },
        .{ .name = "Nats-Service-Error-Code", .value = "404" },
        .{ .name = "Zefir-Rpc-Code", .value = "not_found" },
        .{ .name = "Zefir-Rpc-App-Code", .value = "users.100%25" },
        .{ .name = "Zefir-Rpc-Field", .value = "items[2].%D0%B8%D0%BC%D1%8F" },
        .{ .name = "Zefir-Rpc-Refused", .value = "1" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-trace", .value = "t" },
    };
    try testing.expectEqual(expected.len, owned.headers.len);
    for (expected, owned.headers) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.value, got.value);
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try roundTrip(arena.allocator(), &sent);
    const f = got.status.failure;
    try testing.expectEqual(core.ErrorCode.not_found, f.code);
    try testing.expectEqualStrings("users.100%", f.app_code);
    try testing.expectEqualStrings("User\r\nnot found: 100% sure ", f.message);
    try testing.expectEqualStrings("items[2].имя", f.field.?);
    try testing.expect(got.refused);
    try testing.expectEqualStrings(sent.body, got.body);
    try testing.expectEqual(@as(usize, 1), got.metadata.len);

    // Without a field, a body or refused: four headers.
    const plain = try responseHeaders(testing.allocator, &.{ .status = .{ .failure = .{ .code = .internal, .app_code = "rpc.internal", .message = "Internal error" } } });
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), plain.headers.len);
    const back = try roundTrip(arena.allocator(), &.{ .status = .{ .failure = .{ .code = .internal, .app_code = "rpc.internal", .message = "Internal error" } } });
    try testing.expectEqual(@as(?[]const u8, null), back.status.failure.field);
    try testing.expect(!back.refused);
}

test "every code survives the round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (std.enums.values(core.ErrorCode)) |code| {
        const got = try roundTrip(arena.allocator(), &.{ .status = .{ .failure = .{ .code = code, .app_code = "a", .message = "m" } } });
        try testing.expectEqual(code, got.status.failure.code);
    }
}

test "a failure of a foreign ADR-32 service: code by number, strings as they are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const foreign = try parseResponse(a, "NATS/1.0\r\nNats-Service-Error: 100% done\r\nNats-Service-Error-Code: 409\r\n\r\n", "", default_limits, null);
    const f = foreign.status.failure;
    try testing.expectEqual(core.ErrorCode.aborted, f.code);
    try testing.expectEqualStrings("100% done", f.message);
    try testing.expectEqualStrings("", f.app_code);
    try testing.expectEqual(@as(?[]const u8, null), f.field);
    try testing.expect(!foreign.refused);

    const odd = [_]struct { []const u8, core.ErrorCode }{
        .{ "Nats-Service-Error: x\r\n", .unknown },
        .{ "Nats-Service-Error-Code: 500\r\n", .internal },
        .{ "Nats-Service-Error-Code: 5o0\r\n", .unknown },
        .{ "Nats-Service-Error: x\r\nNats-Service-Error-Code: 404\r\nZefir-Rpc-Code: later_code\r\n", .not_found },
        .{ "Nats-Service-Error: x\r\nNats-Service-Error-Code: 404\r\nZefir-Rpc-Code: aborted\r\n", .aborted },
    };
    for (odd) |case| {
        var block: [256]u8 = undefined;
        const bytes = std.fmt.bufPrint(&block, "NATS/1.0\r\n{s}\r\n", .{case[0]}) catch unreachable;
        try testing.expectEqual(case[1], (try parseResponse(a, bytes, "", default_limits, null)).status.failure.code);
    }
    // Zefir headers without the ADR-32 ones: a success.
    try testing.expect((try parseResponse(a, "NATS/1.0\r\nZefir-Rpc-Code: not_found\r\n\r\n", "x", default_limits, null)).status == .ok);
    // Refused only with "1".
    try testing.expect(!(try parseResponse(a, "NATS/1.0\r\nNats-Service-Error: x\r\nZefir-Rpc-Refused: yes\r\n\r\n", "", default_limits, null)).refused);
}

test "statuses: 503 without a payload is no responders, any other is a protocol violation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, parseResponse(a, "NATS/1.0 503\r\n\r\n", "", default_limits, &d));
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
    try testing.expectError(error.ProtocolViolation, parseResponse(a, "NATS/1.0 503\r\n\r\n", "body", default_limits, &d));
    try testing.expectEqualStrings("a reply with the NATS status 503 and 4 bytes of payload", d.message());
    try testing.expectError(error.ProtocolViolation, parseResponse(a, "NATS/1.0 408 Request Timeout\r\n\r\n", "", default_limits, null));
    try testing.expectError(error.ProtocolViolation, parseResponse(a, "NATS/1.0 100 Idle Heartbeat\r\n\r\n", "", default_limits, null));
}

test "a response over the caller's limits is refused before anything is allocated" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    const small: ResponseLimits = .{ .max_body_bytes = 4, .max_metadata_entries = 2, .max_metadata_bytes = 2 + (3 + 3 + 5) * 2 };
    try testing.expectError(error.ResponseTooLarge, parseResponse(a, "", "12345", small, null));
    try testing.expectError(error.ResponseTooLarge, parseResponse(a, "x-1: a\r\nx-2: b\r\nx-3: c\r\n", "", small, null));
    try testing.expectError(error.ResponseTooLarge, parseResponse(a, "x-1: 12345\r\nx-2: 123456\r\n", "", small, null));
    // The strings of a failure count with the metadata: they are copied too.
    try testing.expectError(error.ResponseTooLarge, parseResponse(a, "x-1: 12345\r\nx-2: 12345\r\nNats-Service-Error: x\r\nZefir-Rpc-Code: internal\r\n", "1234", small, null));
    // The other transport headers do not.
    try testing.expectError(error.OutOfMemory, parseResponse(a, "x-1: 12345\r\nx-2: 12345\r\nNats-Service-Error-Code: 500\r\nZefir-Rpc-Code: internal\r\nZefir-Rpc-Refused: 1\r\n", "1234", small, null));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "the strings of a foreign failure are bounded by the caller's metadata limit, not by max_payload" {
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try block.writer.writeAll("NATS/1.0\r\nNats-Service-Error: ");
    try block.writer.splatByteAll('m', 512 * 1024);
    try block.writer.writeAll("\r\nNats-Service-Error-Code: 500\r\nZefir-Rpc-App-Code: ");
    try block.writer.splatByteAll('a', 256 * 1024);
    try block.writer.writeAll("\r\nZefir-Rpc-Field: ");
    try block.writer.splatByteAll('f', 1024);
    try block.writer.writeAll("\r\n\r\n");
    const kib: ResponseLimits = .{ .max_body_bytes = 1024, .max_metadata_entries = 8, .max_metadata_bytes = 1024 };
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var d: Diagnostics = .{};
    try testing.expectError(error.ResponseTooLarge, parseResponse(failing.allocator(), block.written(), "", kib, &d));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);

    // At the limit, a failure fits: 2 + (3 + 3 + 1) for "x-a: 1", then the
    // message, the app code and the field as they came.
    const fits = "NATS/1.0\r\nX-A: 1\r\nNats-Service-Error: 100% done\r\nNats-Service-Error-Code: 409\r\nZefir-Rpc-App-Code: a.b\r\nZefir-Rpc-Field: id\r\n\r\n";
    const exact: ResponseLimits = .{ .max_body_bytes = 0, .max_metadata_entries = 1, .max_metadata_bytes = 2 + 7 + "100% done".len + "a.b".len + "id".len };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = (try parseResponse(arena.allocator(), fits, "", exact, null)).status.failure;
    try testing.expectEqualStrings("100% done", f.message);
    try testing.expectEqualStrings("a.b", f.app_code);
    try testing.expectEqualStrings("id", f.field.?);
    var one_less = exact;
    one_less.max_metadata_bytes -= 1;
    try testing.expectError(error.ResponseTooLarge, parseResponse(failing.allocator(), fits, "", one_less, null));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a response that runs out of memory frees what it took" {
    const block = "NATS/1.0\r\nNats-Service-Error: m\r\nNats-Service-Error-Code: 404\r\nZefir-Rpc-Code: not_found\r\nX-A: 1\r\n\r\n";
    for (0..2) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, parseResponse(failing.allocator(), block, "body", default_limits, null));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    // Two blocks in all: the entries and the text.
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(counting.allocator());
    defer arena.deinit();
    const response = try parseResponse(arena.allocator(), block, "body", default_limits, null);
    try testing.expectEqualStrings("x-a", response.metadata[0].key);
    try testing.expectEqualStrings("m", response.status.failure.message);
}
