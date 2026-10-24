//! `wire.opmsg`: OP_MSG, the one message of MongoDB's wire protocol that
//! zefir speaks (https://github.com/mongodb/specifications/blob/master/source/message/OP_MSG.md),
//! for both sides of a connection.
//!
//! A message is a header of four int32 (messageLength, requestID,
//! responseTo, opCode 2013), a uint32 of flags, and sections: kind 0 holds
//! the command or the reply, kind 1 a list of documents under an
//! identifier, such as the items of a write. A request goes out as a
//! stream: the caller's body as it is, never copied, with the driver's
//! fields after its elements.
//!
//! ```zig
//! try opmsg.writeRequest(&writer.interface, .{ .request_id = id, .body = ping, .database = "admin" });
//! try writer.interface.flush();
//! const reply = try opmsg.readReply(&reader.interface, gpa, .{ .request_id = id }, &diagnostics);
//! defer reply.deinit();
//! ```
//!
//! Any bytes read give a message or `error.ProtocolViolation`, never a
//! panic; the connection is not to be used after a violation.

const std = @import("std");
const bson = @import("mongo-bson");
const codec = bson.codec;
const errors = @import("../errors.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Diagnostics = errors.Diagnostics;
const Crc = std.hash.crc.@"CRC-32/ISCSI";

pub const op_code: i32 = 2013;
pub const header_len = 16;
/// The shortest message: the header, the flags and a section of kind 0
/// holding `{}`.
pub const min_len = header_len + 4 + 1 + 5;
/// The longest message a server takes before its hello says otherwise.
pub const default_max_message_size: u32 = 48_000_000;

/// The message ends with a CRC-32C of everything before it.
pub const flag_checksum_present: u32 = 1 << 0;
/// More messages follow without a request: for exhaust cursors, and for
/// requests that want no reply.
pub const flag_more_to_come: u32 = 1 << 1;
pub const flag_exhaust_allowed: u32 = 1 << 16;
/// Flags 0 to 15 must be understood; flags 16 to 31 may be ignored.
const required_flags: u32 = 0xffff;
const known_flags: u32 = flag_checksum_present | flag_more_to_come;

pub const Header = struct {
    message_length: i32,
    request_id: i32,
    response_to: i32,
    op_code: i32,

    pub fn parse(bytes: *const [header_len]u8) Header {
        return .{
            .message_length = std.mem.readInt(i32, bytes[0..4], .little),
            .request_id = std.mem.readInt(i32, bytes[4..8], .little),
            .response_to = std.mem.readInt(i32, bytes[8..12], .little),
            .op_code = std.mem.readInt(i32, bytes[12..16], .little),
        };
    }

    pub fn write(h: Header, w: *Writer) Writer.Error!void {
        try w.writeInt(i32, h.message_length, .little);
        try w.writeInt(i32, h.request_id, .little);
        try w.writeInt(i32, h.response_to, .little);
        try w.writeInt(i32, h.op_code, .little);
    }
};

/// A section of kind 1 to send: documents under an identifier.
pub const Sequence = struct {
    /// "documents", "updates" or "deletes" for a write.
    identifier: []const u8,
    documents: []const bson.RawDocument,
};

/// A request as a driver sends it.
pub const Request = struct {
    /// Unique on its connection, so that the reply can be told by it.
    request_id: i32,
    /// The command as the caller gave it; its elements go out unchanged.
    body: bson.RawDocument,
    /// `$db`, which goes out after the body's elements, last.
    database: []const u8,
    /// `ordered`, for a write.
    ordered: ?bool = null,
    /// `maxTimeMS`, under a deadline; it goes out as an int64.
    max_time_ms: ?i64 = null,
    /// The items of a write.
    sequence: ?Sequence = null,

    /// The length of the message that `writeRequest` writes.
    pub fn length(r: Request) usize {
        var n: usize = header_len + 4 + 1 + r.bodyLength();
        if (r.sequence) |sequence| n += 1 + sequenceLength(sequence);
        return n;
    }

    /// The length of the document of kind 0: the body with the driver's
    /// fields.
    fn bodyLength(r: Request) usize {
        // $db: type, "$db" and its 0, the int32 length, the name and its 0.
        var n = r.body.bytes.len + 1 + 4 + 4 + r.database.len + 1;
        // ordered: type, "ordered" and its 0, one byte.
        if (r.ordered != null) n += 1 + 8 + 1;
        // maxTimeMS: type, "maxTimeMS" and its 0, eight bytes.
        if (r.max_time_ms != null) n += 1 + 10 + 8;
        return n;
    }
};

fn sequenceLength(sequence: Sequence) usize {
    var n = 4 + sequence.identifier.len + 1;
    for (sequence.documents) |doc| n += doc.bytes.len;
    return n;
}

pub const WriteError = Writer.Error || error{
    /// The message cannot be written: longer than an int32 can count, a
    /// body that is not a document, or an identifier with a 0 byte.
    InvalidArgument,
};

/// Writes `request` to `w`; flush `w` after it. Nothing is written when it
/// cannot be.
pub fn writeRequest(w: *Writer, request: Request) WriteError!void {
    const body = request.body.bytes;
    if (!codec.isDocument(body)) return error.InvalidArgument;
    if (request.sequence) |sequence| {
        if (std.mem.findScalar(u8, sequence.identifier, 0) != null) return error.InvalidArgument;
    }
    const total = std.math.cast(i32, request.length()) orelse return error.InvalidArgument;
    try (Header{ .message_length = total, .request_id = request.request_id, .response_to = 0, .op_code = op_code }).write(w);
    try w.writeInt(u32, 0, .little);
    try w.writeByte(0);
    try w.writeInt(i32, @intCast(request.bodyLength()), .little);
    try w.writeAll(body[4 .. body.len - 1]);
    if (request.ordered) |ordered| {
        try writeKey(w, .boolean, "ordered");
        try w.writeByte(@intFromBool(ordered));
    }
    if (request.max_time_ms) |ms| {
        try writeKey(w, .int64, "maxTimeMS");
        try w.writeInt(i64, ms, .little);
    }
    try writeKey(w, .string, "$db");
    try w.writeInt(i32, @intCast(request.database.len + 1), .little);
    try w.writeAll(request.database);
    try w.writeAll(&.{ 0, 0 });
    if (request.sequence) |sequence| {
        try w.writeByte(1);
        try w.writeInt(i32, @intCast(sequenceLength(sequence)), .little);
        try w.writeAll(sequence.identifier);
        try w.writeByte(0);
        for (sequence.documents) |doc| try w.writeAll(doc.bytes);
    }
}

fn writeKey(w: *Writer, kind: bson.Type, key: []const u8) Writer.Error!void {
    try w.writeByte(@backingInt(kind));
    try w.writeAll(key);
    try w.writeByte(0);
}

pub const ReadError = Reader.Error || error{
    /// The bytes break OP_MSG; `Diagnostics` says how. Close the
    /// connection.
    ProtocolViolation,
    OutOfMemory,
};

/// What the reply must be.
pub const Expect = struct {
    /// The requestID of the request it answers.
    request_id: i32,
    /// The longest message to take: the server's `maxMessageSizeBytes`,
    /// 48 000 000 before its hello.
    max_message_size: u32 = default_max_message_size,
};

/// Reads the reply to the request `expect.request_id` and returns its
/// document, from `allocator`, after checking it as the minimum of the
/// protocol asks: its responseTo and opCode, a length of 26 bytes to
/// `expect.max_message_size`, no unknown flag among those that must be
/// understood, no moreToCome, one section, of kind 0, a checksum that
/// matches when there is one, and a document valid as BSON that nests a
/// stored document of 100 levels at most (`reply.cursor.firstBatch`
/// adds three). A violation is `error.ProtocolViolation`; the end of the
/// stream before the end of the message is `error.EndOfStream`.
pub fn readReply(r: *Reader, allocator: std.mem.Allocator, expect: Expect, diagnostics: ?*Diagnostics) ReadError!bson.OwnedDocument {
    const head = (try r.takeArray(header_len)).*;
    const header = Header.parse(&head);
    if (header.op_code != op_code) return violation(diagnostics, "the reply is of opCode {d}, not OP_MSG (2013)", .{header.op_code});
    if (header.response_to != expect.request_id) {
        return violation(diagnostics, "the reply answers request {d}; the request was {d}", .{ header.response_to, expect.request_id });
    }
    try checkLength(header.message_length, expect.max_message_size, diagnostics);
    var crc = Crc.init();
    crc.update(&head);
    const flag_bytes = (try r.takeArray(4)).*;
    crc.update(&flag_bytes);
    const flags = std.mem.readInt(u32, &flag_bytes, .little);
    try checkFlags(flags, diagnostics);
    if (flags & flag_more_to_come != 0) return violation(diagnostics, "the reply sets moreToCome, which follows only a request with exhaustAllowed", .{});
    const checksum_len: usize = if (flags & flag_checksum_present != 0) 4 else 0;
    var left = @as(usize, @intCast(header.message_length)) - header_len - 4;
    if (left < checksum_len + 1 + 5) return violation(diagnostics, "the reply is too short for a section of kind 0", .{});
    left -= checksum_len + 1;
    const kind = try r.takeByte();
    crc.update(&.{kind});
    if (kind != 0) return violation(diagnostics, "the reply holds a section of kind {d}; a reply holds one section, of kind 0", .{kind});
    const doc_len = try r.peekInt(i32, .little);
    if (doc_len < 5 or doc_len > left) {
        return violation(diagnostics, "the document of the reply says it is {d} bytes long, and {d} bytes are left of the message", .{ doc_len, left });
    }
    if (doc_len < left) return violation(diagnostics, "the reply holds more than one section; a reply holds one, of kind 0", .{});
    const bytes = try allocator.alloc(u8, left);
    errdefer allocator.free(bytes);
    try r.readSliceAll(bytes);
    crc.update(bytes);
    if (checksum_len != 0 and try r.takeInt(u32, .little) != crc.final()) {
        return violation(diagnostics, "the checksum of the reply does not match its bytes", .{});
    }
    codec.validateDepth(bytes, codec.max_levels) catch return violation(diagnostics, "the document of the reply is not valid BSON, or nests too deep", .{});
    return .{ .bytes = bytes, .allocator = allocator };
}

/// A request as a server reads it.
pub const Incoming = struct {
    header: Header,
    flags: u32,
    /// The document of kind 0: the command, with the driver's fields.
    body: bson.RawDocument,
    /// The sections, after the flags.
    sections: []const u8,
    /// The message after its header.
    bytes: []const u8,
    allocator: std.mem.Allocator,

    /// The sections of kind 1, in their order.
    pub fn sequences(m: *const Incoming) Sequences {
        return .{ .bytes = m.sections };
    }

    pub fn deinit(m: Incoming) void {
        m.allocator.free(m.bytes);
    }
};

/// The sections of kind 1 of a request that `readRequest` checked.
pub const Sequences = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(it: *Sequences) ?Section {
        while (it.bytes.len - it.pos >= 5) {
            const kind = it.bytes[it.pos];
            const len: usize = @intCast(@max(0, std.mem.readInt(i32, it.bytes[it.pos + 1 ..][0..4], .little)));
            if (len < 4 or len > it.bytes.len - it.pos - 1) return null;
            const section = it.bytes[it.pos + 1 ..][0..len];
            it.pos += 1 + len;
            if (kind != 1) continue;
            const end = std.mem.findScalarPos(u8, section, 4, 0) orelse return null;
            return .{ .identifier = section[4..end], .bytes = section[end + 1 ..] };
        }
        return null;
    }
};

/// A section of kind 1 that a server read.
pub const Section = struct {
    identifier: []const u8,
    /// The documents, one after another.
    bytes: []const u8,

    pub fn documents(s: Section) Documents {
        return .{ .bytes = s.bytes };
    }
};

pub const Documents = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(it: *Documents) ?bson.RawDocument {
        if (it.bytes.len - it.pos < 5) return null;
        const len = std.math.cast(usize, std.mem.readInt(i32, it.bytes[it.pos..][0..4], .little)) orelse return null;
        if (len < 5 or len > it.bytes.len - it.pos) return null;
        defer it.pos += len;
        return .{ .bytes = it.bytes[it.pos..][0..len] };
    }
};

/// Reads a request, as a server does: an OP_MSG of 26 bytes to
/// `max_message_size`, no unknown flag among those that must be
/// understood, a checksum that matches when there is one, one section of
/// kind 0 and any number of kind 1, each document valid as BSON. Another
/// opCode, OP_QUERY among them, is `error.ProtocolViolation`.
pub fn readRequest(r: *Reader, allocator: std.mem.Allocator, max_message_size: u32, diagnostics: ?*Diagnostics) ReadError!Incoming {
    const head = (try r.takeArray(header_len)).*;
    const header = Header.parse(&head);
    if (header.op_code != op_code) return violation(diagnostics, "the message is of opCode {d}; this side speaks OP_MSG (2013) only", .{header.op_code});
    try checkLength(header.message_length, max_message_size, diagnostics);
    const bytes = try allocator.alloc(u8, @as(usize, @intCast(header.message_length)) - header_len);
    errdefer allocator.free(bytes);
    try r.readSliceAll(bytes);
    const flags = std.mem.readInt(u32, bytes[0..4], .little);
    try checkFlags(flags, diagnostics);
    var end = bytes.len;
    if (flags & flag_checksum_present != 0) {
        if (end < 4 + 4) return violation(diagnostics, "the message is too short for its checksum", .{});
        end -= 4;
        var crc = Crc.init();
        crc.update(&head);
        crc.update(bytes[0..end]);
        if (std.mem.readInt(u32, bytes[end..][0..4], .little) != crc.final()) {
            return violation(diagnostics, "the checksum of the message does not match its bytes", .{});
        }
    }
    const sections = bytes[4..end];
    const body = try checkSections(sections, diagnostics);
    return .{ .header = header, .flags = flags, .body = body, .sections = sections, .bytes = bytes, .allocator = allocator };
}

/// Writes `reply`, the answer to the request `response_to`, as a server
/// does; flush `w` after it.
pub fn writeReply(w: *Writer, request_id: i32, response_to: i32, reply: bson.RawDocument) WriteError!void {
    if (!codec.isDocument(reply.bytes)) return error.InvalidArgument;
    const total = std.math.cast(i32, header_len + 4 + 1 + reply.bytes.len) orelse return error.InvalidArgument;
    try (Header{ .message_length = total, .request_id = request_id, .response_to = response_to, .op_code = op_code }).write(w);
    try w.writeInt(u32, 0, .little);
    try w.writeByte(0);
    try w.writeAll(reply.bytes);
}

/// Checks the sections of a request and returns its document of kind 0.
fn checkSections(sections: []const u8, diagnostics: ?*Diagnostics) ReadError!bson.RawDocument {
    var body: ?bson.RawDocument = null;
    var pos: usize = 0;
    while (pos < sections.len) {
        const kind = sections[pos];
        pos += 1;
        if (kind > 1) return violation(diagnostics, "the message holds a section of kind {d}; this side knows kinds 0 and 1", .{kind});
        if (sections.len - pos < 4) return violation(diagnostics, "a section of kind {d} is cut short", .{kind});
        const len = std.mem.readInt(i32, sections[pos..][0..4], .little);
        if (len < 5 or len > sections.len - pos) {
            return violation(diagnostics, "a section of kind {d} says it is {d} bytes long, and {d} bytes are left of the message", .{ kind, len, sections.len - pos });
        }
        const section = sections[pos..][0..@intCast(len)];
        pos += section.len;
        if (kind == 0) {
            if (body != null) return violation(diagnostics, "the message holds two sections of kind 0", .{});
            codec.validateDepth(section, codec.max_levels) catch return violation(diagnostics, "the document of kind 0 is not valid BSON, or nests too deep", .{});
            body = .{ .bytes = section };
            continue;
        }
        const end = std.mem.findScalarPos(u8, section, 4, 0) orelse return violation(diagnostics, "the identifier of a section of kind 1 has no end", .{});
        const identifier = section[4..end];
        var at = end + 1;
        var index: usize = 0;
        while (at < section.len) : (index += 1) {
            if (section.len - at < 5) return violation(diagnostics, "document {d} of section '{s}' is cut short", .{ index, identifier });
            const doc_len = std.mem.readInt(i32, section[at..][0..4], .little);
            if (doc_len < 5 or doc_len > section.len - at) return violation(diagnostics, "document {d} of section '{s}' is cut short", .{ index, identifier });
            codec.validateDepth(section[at..][0..@intCast(doc_len)], codec.max_levels) catch {
                return violation(diagnostics, "document {d} of section '{s}' is not valid BSON, or nests too deep", .{ index, identifier });
            };
            at += @intCast(doc_len);
        }
    }
    return body orelse violation(diagnostics, "the message holds no section of kind 0", .{});
}

fn checkLength(length: i32, max: u32, diagnostics: ?*Diagnostics) ReadError!void {
    if (length < min_len or length > max) {
        return violation(diagnostics, "the message says it is {d} bytes long; a message here is {d} to {d} bytes", .{ length, min_len, max });
    }
}

fn checkFlags(flags: u32, diagnostics: ?*Diagnostics) ReadError!void {
    const unknown = flags & required_flags & ~known_flags;
    if (unknown != 0) return violation(diagnostics, "the message sets flag bits 0x{x} that must be understood, and this side does not know them", .{unknown});
}

fn violation(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{ProtocolViolation} {
    if (diagnostics) |d| d.set(.receive, null, fmt, args);
    return error.ProtocolViolation;
}
