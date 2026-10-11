//! Encodes records as JSON Lines or text into a caller's buffer. The
//! message, the keys and literal field values are rendered at compile
//! time; at run time only the timestamp, the service fragment (encoded once
//! at `init`), the scope and runtime values are written.

const std = @import("std");
const escape = @import("escape.zig");
const field_checks = @import("fields.zig");
const redact = @import("redact.zig");
const options = @import("options.zig");
const timestamp = @import("timestamp.zig");
const Level = @import("level.zig").Level;

const Format = options.Format;
const Writer = std.Io.Writer;
const testing = std.testing;

/// Objects, arrays and unions nested deeper than this are written as
/// "[MAX_DEPTH]", so a cycle through pointers ends.
const max_depth = 8;
const depth_marker = "[MAX_DEPTH]";

/// How a value is written. `fields.check` has ruled out every type that
/// fits none of these.
const Class = enum { redacted, log_value, format, string, scalar, optional, pointer, sequence, object, tagged };

fn classOf(comptime T: type) Class {
    if (field_checks.redactsWhole(T)) return .redacted;
    if (field_checks.LogValue(T) != null) return .log_value;
    if (field_checks.hasFormat(T)) return .format;
    if (field_checks.isString(T)) return .string;
    return switch (@typeInfo(T)) {
        .optional => .optional,
        .pointer => |p| if (p.size == .one) .pointer else .sequence,
        .array, .vector => .sequence,
        .@"struct" => |s| if (s.is_tuple) .sequence else .object,
        .@"union" => .tagged,
        else => .scalar,
    };
}

/// Writes one value: JSON, or text as it reads inside a field.
fn writeValue(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    return switch (f) {
        .json => writeJson(w, value, 0),
        .text => writeText(w, value, 0, false),
    };
}

fn writeJson(w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    const T = @TypeOf(value);
    const too_deep = "\"" ++ depth_marker ++ "\"";
    switch (comptime classOf(T)) {
        .redacted => try w.writeAll("\"" ++ redact.placeholder ++ "\""),
        .log_value => if (depth == max_depth) try w.writeAll(too_deep) else try writeJson(w, value.logValue(), depth + 1),
        .format => try writeFormatted(.json, w, value, false),
        .string => try writeString(.json, w, stringOf(&value), false),
        .scalar => try writeScalar(.json, w, value, false),
        .optional => if (value) |payload| try writeJson(w, payload, depth) else try w.writeAll("null"),
        .pointer => try writeJson(w, deref(value), depth),
        .sequence => if (depth == max_depth) try w.writeAll(too_deep) else {
            try w.writeByte('[');
            try writeItems(.json, w, value, depth + 1);
            try w.writeByte(']');
        },
        .object => if (depth == max_depth) try w.writeAll(too_deep) else {
            try w.writeByte('{');
            try writeMembers(.json, w, value, depth + 1);
            try w.writeByte('}');
        },
        .tagged => if (depth == max_depth) try w.writeAll(too_deep) else try writeTagged(.json, w, value, depth + 1),
    }
}

/// A value inside a text field: scalars and strings as they are, the rest
/// inline: `[1,2]`, `{host=pg,port=5432}`. `nested` is set inside a
/// composite, where strings with `,[]{}` take quotes too.
fn writeText(w: *Writer, value: anytype, comptime depth: u8, comptime nested: bool) Writer.Error!void {
    const T = @TypeOf(value);
    switch (comptime classOf(T)) {
        .redacted => try w.writeAll(redact.placeholder),
        .log_value => if (depth == max_depth) try w.writeAll(depth_marker) else try writeText(w, value.logValue(), depth + 1, nested),
        .format => try writeFormatted(.text, w, value, nested),
        .string => try writeString(.text, w, stringOf(&value), nested),
        .scalar => try writeScalar(.text, w, value, nested),
        .optional => if (value) |payload| try writeText(w, payload, depth, nested) else try w.writeAll("null"),
        .pointer => try writeText(w, deref(value), depth, nested),
        .sequence => if (depth == max_depth) try w.writeAll(depth_marker) else {
            try w.writeByte('[');
            try writeItems(.text, w, value, depth + 1);
            try w.writeByte(']');
        },
        .object => if (depth == max_depth) try w.writeAll(depth_marker) else {
            try w.writeByte('{');
            try writeMembers(.text, w, value, depth + 1);
            try w.writeByte('}');
        },
        .tagged => if (depth == max_depth) try w.writeAll(depth_marker) else try writeTagged(.text, w, value, depth + 1),
    }
}

/// A value inside an array, an object or a union.
fn writeNested(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    return switch (f) {
        .json => writeJson(w, value, depth),
        .text => writeText(w, value, depth, true),
    };
}

fn writeItems(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        // A tuple: its items may be known at compile time.
        .@"struct" => |s| inline for (s.field_names, s.field_types, s.field_attrs, 0..) |name, Item, attrs, i| {
            if (i > 0) try w.writeByte(',');
            if (attrs.@"comptime" and comptime renderAtComptime(Item))
                try w.writeAll(comptime renderedNested(f, @field(value, name), depth))
            else
                try writeNested(f, w, @field(value, name), depth);
        },
        .vector => |v| {
            const items: [v.len]v.child = value;
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeNested(f, w, item, depth);
            }
        },
        else => for (value, 0..) |item, i| {
            if (i > 0) try w.writeByte(',');
            try writeNested(f, w, item, depth);
        },
    }
}

/// `"name":value` (JSON) or `name=value` (text) pairs, comma-separated.
fn writeMembers(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    const s = @typeInfo(@TypeOf(value)).@"struct";
    comptime var first = true;
    inline for (s.field_names, s.field_types, s.field_attrs) |name, Member, attrs| {
        if (Member == void) continue;
        try w.writeAll(comptime (if (first) "" else ",") ++ memberKey(f, name));
        first = false;
        if (comptime redact.isSensitiveName(name))
            try w.writeAll(comptime placeholderToken(f))
        else if (attrs.@"comptime" and comptime renderAtComptime(Member))
            try w.writeAll(comptime renderedNested(f, @field(value, name), depth))
        else
            try writeNested(f, w, @field(value, name), depth);
    }
}

/// `{"tag":payload}` or `{tag=payload}`; a void payload is `{}`.
fn writeTagged(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            try w.writeAll(comptime "{" ++ memberKey(f, name));
            if (comptime redact.isSensitiveName(name))
                try w.writeAll(comptime placeholderToken(f))
            else if (@TypeOf(payload) == void)
                try w.writeAll("{}")
            else
                try writeNested(f, w, payload, depth);
            try w.writeByte('}');
        },
    }
}

fn memberKey(comptime f: Format, comptime name: []const u8) []const u8 {
    return switch (f) {
        .json => "\"" ++ name ++ "\":",
        .text => name ++ "=",
    };
}

fn placeholderToken(comptime f: Format) []const u8 {
    return switch (f) {
        .json => "\"" ++ redact.placeholder ++ "\"",
        .text => redact.placeholder,
    };
}

/// One field of a text record: ` path=value`. An object or a union reached
/// from the field through objects, unions, pointers and `logValue` is
/// spread into one ` path.member=value` per member instead.
fn writeTextField(w: *Writer, comptime path: []const u8, value: anytype, comptime depth: u8) Writer.Error!void {
    const T = @TypeOf(value);
    if (depth < max_depth) switch (comptime classOf(T)) {
        .log_value => return writeTextField(w, path, value.logValue(), depth + 1),
        .pointer => if (@typeInfo(@typeInfo(T).pointer.child) != .array) return writeTextField(w, path, value.*, depth),
        .object => {
            const s = @typeInfo(T).@"struct";
            comptime var empty = true;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, Member, attrs| {
                if (Member == void) continue;
                empty = false;
                const member = path ++ "." ++ name;
                if (comptime redact.isSensitiveName(name))
                    try w.writeAll(" " ++ member ++ "=" ++ redact.placeholder)
                else if (attrs.@"comptime" and comptime renderAtComptime(Member))
                    try w.writeAll(comptime renderedTextField(member, @field(value, name), depth + 1))
                else
                    try writeTextField(w, member, @field(value, name), depth + 1);
            }
            if (empty) try w.writeAll(" " ++ path ++ "={}");
            return;
        },
        .tagged => switch (value) {
            inline else => |payload, tag| {
                const member = path ++ "." ++ @tagName(tag);
                if (comptime redact.isSensitiveName(@tagName(tag)))
                    try w.writeAll(" " ++ member ++ "=" ++ redact.placeholder)
                else if (@TypeOf(payload) == void)
                    try w.writeAll(" " ++ member ++ "={}")
                else
                    try writeTextField(w, member, payload, depth + 1);
                return;
            },
        },
        else => {},
    };
    try w.writeAll(" " ++ path ++ "=");
    try writeText(w, value, depth, false);
}

/// What `value.format(writer)` writes, as a string: escaped, in quotes for
/// JSON, and bare in text when nothing in it needs quotes.
fn writeFormatted(comptime f: Format, w: *Writer, value: anytype, comptime nested: bool) Writer.Error!void {
    if (f == .text) {
        // A dry run tells whether the text needs quotes.
        var sink: Writer.Discarding = .init(&.{});
        var probe: escape.Escaper = undefined;
        probe.init(&sink.writer);
        probe.strict = nested;
        value.format(&probe.writer) catch {};
        probe.finish() catch {};
        if (probe.plain and probe.count > 0) return formatEscaped(w, value);
    }
    try w.writeByte('"');
    try formatEscaped(w, value);
    try w.writeByte('"');
}

fn formatEscaped(w: *Writer, value: anytype) Writer.Error!void {
    var e: escape.Escaper = undefined;
    e.init(w);
    try value.format(&e.writer);
    try e.finish();
}

/// The string a string-like value holds. Takes a pointer, so an array
/// argument is not copied into a slice that outlives it.
fn stringOf(ptr: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(T)) {
        .array => ptr,
        .pointer => |p| switch (p.size) {
            .slice, .one => ptr.*,
            .many => std.mem.span(ptr.*),
            .c => unreachable,
        },
        else => unreachable,
    };
}

/// What a single-item pointer points to; a pointer to an array gives a
/// slice, so the array is not copied.
fn deref(ptr: anytype) Deref(@TypeOf(ptr)) {
    return switch (@typeInfo(@typeInfo(@TypeOf(ptr)).pointer.child)) {
        .array => ptr,
        else => ptr.*,
    };
}

fn Deref(comptime P: type) type {
    const Child = @typeInfo(P).pointer.child;
    return switch (@typeInfo(Child)) {
        .array => |a| []const a.child,
        else => Child,
    };
}

fn writeScalar(comptime f: Format, w: *Writer, value: anytype, comptime nested: bool) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int => |int| if (int.bits <= 64) try w.print("{d}", .{value}) else try writeQuotedDigits(f, w, value),
        .comptime_int => if (value >= std.math.minInt(i64) and value <= std.math.maxInt(u64))
            try w.print("{d}", .{value})
        else
            try writeQuotedDigits(f, w, value),
        .float => try writeFloat(f, w, value),
        // f128 keeps the literal's range and digits; literal fields are
        // rendered at compile time, so this costs nothing at run time.
        .comptime_float => try writeFloat(f, w, @as(f128, value)),
        .null => try w.writeAll("null"),
        // Every value of an exhaustive enum has a name: one table lookup.
        .@"enum" => |e| if (e.mode == .exhaustive)
            try writeString(f, w, @tagName(value), nested)
        else if (std.enums.tagName(T, value)) |name|
            try writeString(f, w, name, nested)
        else
            try writeQuotedDigits(f, w, @backingInt(value)),
        .enum_literal => try writeString(f, w, @tagName(value), nested),
        .error_set => try writeString(f, w, @errorName(value), nested),
        .type => try writeString(f, w, @typeName(value), nested),
        else => @compileError("unreachable: fields.check lets no other type through"),
    }
}

/// A JSON string, or a text value: bare when it is safe, else quoted.
fn writeString(comptime f: Format, w: *Writer, s: []const u8, comptime nested: bool) Writer.Error!void {
    if (f == .text and escape.isBare(s) and !(nested and std.mem.findAny(u8, s, ",[]{}") != null))
        return w.writeAll(s);
    try w.writeByte('"');
    try escape.write(w, s);
    try w.writeByte('"');
}

/// Digits that JSON gets as a string: integers wider than 64 bits and
/// unnamed values of non-exhaustive enums.
fn writeQuotedDigits(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    if (f == .json) try w.writeByte('"');
    try w.print("{d}", .{value});
    if (f == .json) try w.writeByte('"');
}

fn writeFloat(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    const quote = if (f == .json) "\"" else "";
    if (std.math.isNan(value)) return w.writeAll(quote ++ "NaN" ++ quote);
    if (std.math.isInf(value)) return w.writeAll(if (value > 0) quote ++ "+Inf" ++ quote else quote ++ "-Inf" ++ quote);
    // Compared in a wide type: f16 cannot hold 1e21.
    const Wide = if (@typeInfo(@TypeOf(value)).float.bits <= 64) f64 else f128;
    const magnitude: Wide = @abs(value);
    if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) {
        try w.print("{d}", .{value});
    } else {
        try w.print("{e}", .{value});
    }
}

/// The separator and the key of a top-level field: `,"name":` or ` name=`.
/// Field names are limited to [A-Za-z0-9_.-], so they never need escaping.
fn key(comptime f: Format, comptime name: []const u8) []const u8 {
    return switch (f) {
        .json => ",\"" ++ name ++ "\":",
        .text => " " ++ name ++ "=",
    };
}

fn writeField(comptime f: Format, w: *Writer, comptime name: []const u8, value: anytype) Writer.Error!void {
    switch (f) {
        .json => {
            try w.writeAll(comptime key(.json, name));
            try writeJson(w, value, 0);
        },
        .text => try writeTextField(w, name, value, 0),
    }
}

/// A field whose value is known at compile time, rendered once: at run
/// time it costs one copy.
fn literalField(comptime f: Format, comptime name: []const u8, comptime value: anytype) []const u8 {
    return rendered(struct {
        fn write(w: *Writer) Writer.Error!void {
            return writeField(f, w, name, value);
        }
    }.write);
}

/// `writeNested` for a value known at compile time.
fn renderedNested(comptime f: Format, comptime value: anytype, comptime depth: u8) []const u8 {
    return rendered(struct {
        fn write(w: *Writer) Writer.Error!void {
            return writeNested(f, w, value, depth);
        }
    }.write);
}

/// `writeTextField` for a value known at compile time.
fn renderedTextField(comptime path: []const u8, comptime value: anytype, comptime depth: u8) []const u8 {
    return rendered(struct {
        fn write(w: *Writer) Writer.Error!void {
            return writeTextField(w, path, value, depth);
        }
    }.write);
}

/// What `write` writes, computed at compile time.
fn rendered(comptime write: fn (*Writer) Writer.Error!void) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var counter: Writer.Discarding = .init(&.{});
        write(&counter.writer) catch unreachable;
        var buf: [@intCast(counter.count + counter.writer.end)]u8 = undefined;
        var w: Writer = .fixed(&buf);
        write(&w) catch unreachable;
        const final = buf;
        break :blk &final;
    };
}

/// Whether a value known at compile time may also be written then. Not
/// when it reads through a pointer that is not const: the address of a
/// global `var` is known at compile time, what it holds is not.
fn renderAtComptime(comptime T: type) bool {
    return !readsMutable(T, &.{});
}

fn readsMutable(comptime T: type, comptime visited: []const type) bool {
    for (visited) |seen| {
        if (seen == T) return false;
    }
    const next = visited ++ [_]type{T};
    return switch (@typeInfo(T)) {
        .pointer => |p| !p.attrs.@"const" or readsMutable(p.child, next),
        .optional => |o| readsMutable(o.child, next),
        .array => |a| readsMutable(a.child, next),
        .@"struct" => |s| for (s.field_types) |Member| {
            if (readsMutable(Member, next)) break true;
        } else false,
        .@"union" => |u| for (u.field_types) |Payload| {
            if (readsMutable(Payload, next)) break true;
        } else false,
        else => false,
    };
}

fn redactedField(comptime f: Format, comptime name: []const u8) []const u8 {
    return key(f, name) ++ placeholderToken(f);
}

/// What the engine adds to every record.
pub const Header = struct {
    timestamp: std.Io.Timestamp,
    /// `,"service.name":"…"…`, ready to copy; empty for text.
    service: []const u8,
    /// The scope, escaped; empty without a scope.
    scope: []const u8,
    /// The text format writes the scope in quotes: it has a space, `=`,
    /// a bracket or an escape that would make it pass for something else.
    scope_quoted: bool = false,
    /// How a `.src` field is written at this record's level.
    source: options.SourceMode = .file_line,
    /// The trace ids the record carries; null without a trace.
    trace: ?*const TraceHex = null,
    oversize: options.OversizePolicy,
};

/// The ids of a trace, as lowercase hex.
pub const TraceHex = struct { trace_id: [32]u8, span_id: [16]u8 };

pub const Encoded = struct {
    /// Bytes written, '\n' included.
    len: usize,
    /// The record was cut and ends with the truncation marker.
    truncated: bool,
};

const ellipsis = "…";

const Closing = struct { whole: []const u8, cut: []const u8 };

fn closing(comptime f: Format) Closing {
    return switch (f) {
        .json => .{ .whole = "}\n", .cut = ",\"truncated\":true}\n" },
        .text => .{ .whole = "\n", .cut = " truncated=true\n" },
    };
}

/// Encodes one record into `out`, '\n' included. A record that fits is
/// written whole. One that does not is cut (`.truncate`: the message loses
/// its end, the call site and the fields that do not fit are left out, and
/// the record ends with the truncation marker) or not written at all
/// (`.drop`: null).
pub fn record(
    comptime f: Format,
    comptime level: Level,
    comptime message: []const u8,
    out: []u8,
    header: Header,
    fields: anytype,
) ?Encoded {
    var source_buf: [max_source_bytes]u8 = undefined;
    const source = sourceOf(f, fields, header.source, &source_buf);
    return encodeRecord(f, level, Literal(message){}, out, header, source, fields);
}

/// `record` for a message formatted at run time, as std.log gives it.
pub fn recordFormatted(
    comptime f: Format,
    comptime level: Level,
    comptime format: []const u8,
    args: anytype,
    out: []u8,
    header: Header,
) ?Encoded {
    const message: Formatted(format, @TypeOf(args)) = .{ .args = args };
    return encodeRecord(f, level, message, out, header, "", .{});
}

fn encodeRecord(
    comptime f: Format,
    comptime level: Level,
    message: anytype,
    out: []u8,
    header: Header,
    source: []const u8,
    fields: anytype,
) ?Encoded {
    var stamp: [timestamp.len]u8 = undefined;
    timestamp.format(header.timestamp, &stamp);
    var ids_buf: [idsLen(f)]u8 = undefined;
    const ids: []const u8 = if (header.trace) |trace| idsFragment(f, trace, &ids_buf) else "";
    const parts: Parts = .{ .stamp = &stamp, .source = source, .ids = ids };
    if (encode(f, level, message, out, header, parts, fields, false)) |len| return .{ .len = len, .truncated = false };
    if (header.oversize == .drop) return null;
    const len = encode(f, level, message, out, header, parts, fields, true) orelse return null;
    return .{ .len = len, .truncated = true };
}

/// What `record` prepares once for both passes.
const Parts = struct {
    stamp: *const [timestamp.len]u8,
    /// The call site, ready to copy; empty without one.
    source: []const u8,
    /// The trace ids, ready to copy; empty without them.
    ids: []const u8,
};

/// One pass of `record`. Whole: everything must fit, else null. Cut: the
/// message, the call site and the fields give way, and the record ends
/// with the truncation marker.
fn encode(
    comptime f: Format,
    comptime level: Level,
    message: anytype,
    out: []u8,
    header: Header,
    parts: Parts,
    fields: anytype,
    comptime cut: bool,
) ?usize {
    const close = comptime if (cut) closing(f).cut else closing(f).whole;
    if (out.len < close.len) return null;
    var w: Writer = .fixed(out[0 .. out.len - close.len]);
    const source = writeHead(f, level, message, &w, header, parts, cut) catch return null;
    switch (f) {
        .json => writeFields(f, &w, fields, cut) catch return null,
        .text => {
            // The trace ids and the call site go last in text: the fields
            // give way to them.
            const tail = parts.ids.len + source.len;
            const full = w.buffer;
            if (w.end + tail > full.len) return null;
            w.buffer = full[0 .. full.len - tail];
            const written = writeFields(f, &w, fields, cut);
            w.buffer = full;
            written catch return null;
            w.writeAll(parts.ids) catch return null;
            w.writeAll(source) catch return null;
        },
    }
    @memcpy(out[w.end..][0..close.len], close);
    return w.end + close.len;
}

/// Writes the head of the record and returns the call site still to
/// write: the one in `parts`, or nothing when it gave way to the message.
fn writeHead(
    comptime f: Format,
    comptime level: Level,
    message: anytype,
    w: *Writer,
    header: Header,
    parts: Parts,
    comptime cut: bool,
) Writer.Error![]const u8 {
    switch (f) {
        .json => {
            try w.writeAll("{\"timestamp\":\"");
            try w.writeAll(parts.stamp);
            try w.writeAll(comptime "\",\"level\":\"" ++ level.asText() ++ "\",\"message\":\"");
            const scope_len = if (header.scope.len > 0) ",\"scope\":\"".len + header.scope.len + 1 else 0;
            const keep = header.service.len + scope_len + parts.ids.len;
            const source = try writeMessageBeside(w, message, "", "\"", keep, parts.source, cut);
            try w.writeAll(header.service);
            if (header.scope.len > 0) {
                try w.writeAll(",\"scope\":\"");
                try w.writeAll(header.scope);
                try w.writeByte('"');
            }
            try w.writeAll(source);
            try w.writeAll(parts.ids);
            return source;
        },
        .text => {
            try w.writeAll(parts.stamp);
            try w.writeAll(comptime " " ++ level.label());
            if (header.scope.len > 0) {
                try w.writeAll(if (header.scope_quoted) " [\"" else " [");
                try w.writeAll(header.scope);
                try w.writeAll(if (header.scope_quoted) "\"]" else "]");
            }
            if (comptime @TypeOf(message).empty)
                return if (!cut or parts.ids.len + parts.source.len <= w.unusedCapacityLen()) parts.source else "";
            return writeMessageBeside(w, message, " ", "", parts.ids.len, parts.source, cut);
        },
    }
}

/// Writes the message, keeping room for the `keep` bytes that follow it
/// and, while the message still fits in some form, for the call site.
/// Returns the call site to write, or nothing when it gave way.
fn writeMessageBeside(
    w: *Writer,
    message: anytype,
    comptime open: []const u8,
    comptime close: []const u8,
    keep: usize,
    source: []const u8,
    comptime cut: bool,
) Writer.Error![]const u8 {
    if (!cut) {
        try message.write(w, open, close, 0, false);
        return source;
    }
    // A failed cut write leaves the writer as it was, so it can be retried.
    message.write(w, open, close, keep + source.len, true) catch |e| {
        if (source.len == 0) return e;
        try message.write(w, open, close, keep, true);
        return "";
    };
    return source;
}

/// A message known at compile time: escaped then, cut at run time.
fn Literal(comptime message: []const u8) type {
    return struct {
        const empty = message.len == 0;

        /// Writes `open`, the escaped message and `close`, leaving `keep`
        /// bytes free. In a cut pass a message that does not fit loses its
        /// end, between characters, and ends with "…"; when even that does
        /// not fit, nothing is written.
        fn write(_: @This(), w: *Writer, comptime open: []const u8, comptime close: []const u8, keep: usize, comptime cut: bool) Writer.Error!void {
            const escaped = comptime escapedLiteral(message);
            const free = w.unusedCapacityLen();
            if (!cut or open.len + escaped.len + close.len + keep <= free) {
                return w.writeAll(open ++ escaped ++ close);
            }
            const fixed_len = open.len + ellipsis.len + close.len + keep;
            if (fixed_len > free) return error.WriteFailed;
            const n = escape.fittingPrefix(message, free - fixed_len);
            try w.writeAll(open);
            try escape.write(w, message[0..n]);
            try w.writeAll(ellipsis ++ close);
        }
    };
}

/// A message formatted at run time: escaped as it is formatted.
fn Formatted(comptime format: []const u8, comptime Args: type) type {
    return struct {
        args: Args,

        const empty = format.len == 0;

        /// As `Literal.write`; a cut pass formats the message twice, once
        /// to measure it.
        fn write(m: @This(), w: *Writer, comptime open: []const u8, comptime close: []const u8, keep: usize, comptime cut: bool) Writer.Error!void {
            if (!cut) {
                try w.writeAll(open);
                try m.print(w, null);
                return w.writeAll(close);
            }
            const free = w.unusedCapacityLen();
            if (open.len + ellipsis.len + close.len + keep > free) return error.WriteFailed;
            const room = free - open.len - close.len - keep;
            var sink: Writer.Discarding = .init(&.{});
            var probe: escape.Escaper = undefined;
            probe.init(&sink.writer);
            probe.writer.print(format, m.args) catch {};
            probe.finish() catch {};
            try w.writeAll(open);
            if (probe.count <= room) {
                try m.print(w, null);
            } else {
                try m.print(w, room - ellipsis.len);
                try w.writeAll(ellipsis);
            }
            try w.writeAll(close);
        }

        fn print(m: @This(), w: *Writer, budget: ?usize) Writer.Error!void {
            var e: escape.Escaper = undefined;
            e.init(w);
            e.budget = budget;
            try e.writer.print(format, m.args);
            try e.finish();
        }
    };
}

fn idsLen(comptime f: Format) usize {
    return switch (f) {
        .json => ",\"trace_id\":\"".len + 32 + "\",\"span_id\":\"".len + 16 + "\"".len,
        .text => " trace_id=".len + 32 + " span_id=".len + 16,
    };
}

/// `,"trace_id":"…","span_id":"…"` in JSON, ` trace_id=… span_id=…` in text.
fn idsFragment(comptime f: Format, trace: *const TraceHex, buf: *[idsLen(f)]u8) []const u8 {
    const before_trace, const before_span, const after = switch (f) {
        .json => .{ ",\"trace_id\":\"", "\",\"span_id\":\"", "\"" },
        .text => .{ " trace_id=", " span_id=", "" },
    };
    var w: Writer = .fixed(buf);
    for ([_][]const u8{ before_trace, &trace.trace_id, before_span, &trace.span_id, after }) |part| {
        w.writeAll(part) catch unreachable; // `buf` is exactly this long
    }
    return buf;
}

/// The longest call site written from a value known only at run time; a
/// longer one is left out.
const max_source_bytes = 1024;

/// The call-site fragment of a record whose fields have `.src`, in `mode`.
/// A call site known at compile time (`.src = @src()`) is rendered then.
fn sourceOf(comptime f: Format, fields: anytype, mode: options.SourceMode, buf: *[max_source_bytes]u8) []const u8 {
    const Fields = @TypeOf(fields);
    const name = field_checks.source_field;
    if (comptime !@hasField(Fields, name)) return "";
    if (mode == .none) return "";
    const info = @typeInfo(Fields).@"struct";
    const index = comptime for (info.field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) break i;
    } else unreachable;
    if (comptime info.field_attrs[index].@"comptime") {
        const src = @field(fields, name);
        return switch (mode) {
            .none => unreachable,
            .file_line => comptime renderedSource(f, src, .file_line),
            .full => comptime renderedSource(f, src, .full),
        };
    }
    var w: Writer = .fixed(buf);
    writeSource(f, &w, @field(fields, name), mode) catch return "";
    return w.buffered();
}

/// `,"source":{"file":…,"line":…}` in JSON, ` src=file:line` in text.
fn writeSource(comptime f: Format, w: *Writer, src: std.lang.SourceLocation, mode: options.SourceMode) Writer.Error!void {
    switch (f) {
        .json => {
            try w.writeAll(",\"source\":{\"file\":\"");
            try escape.write(w, src.file);
            try w.print("\",\"line\":{d}", .{src.line});
            if (mode == .full) {
                try w.print(",\"column\":{d},\"function\":\"", .{src.column});
                try escape.write(w, functionName(src.fn_name));
                try w.writeAll("\",\"module\":\"");
                try escape.write(w, src.module);
                try w.writeByte('"');
            }
            try w.writeByte('}');
        },
        .text => {
            const bare = escape.isBare(src.file);
            try w.writeAll(if (bare) " src=" else " src=\"");
            try escape.write(w, src.file);
            try w.print(":{d}", .{src.line});
            if (mode == .full) try w.print(":{d}", .{src.column});
            if (!bare) try w.writeByte('"');
            if (mode == .full) {
                try w.writeAll(" function=");
                try writeString(.text, w, functionName(src.fn_name), false);
                try w.writeAll(" module=");
                try writeString(.text, w, src.module, false);
            }
        },
    }
}

fn renderedSource(comptime f: Format, comptime src: std.lang.SourceLocation, comptime mode: options.SourceMode) []const u8 {
    return rendered(struct {
        fn write(w: *Writer) Writer.Error!void {
            return writeSource(f, w, src, mode);
        }
    }.write);
}

/// `name` without the `__func_<n>` suffix that generic functions get, so
/// the same function logs the same name in every build.
fn functionName(name: []const u8) []const u8 {
    const suffix = "__func_";
    const at = std.mem.findLast(u8, name, suffix) orelse return name;
    const digits = name[at + suffix.len ..];
    if (digits.len == 0) return name;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return name;
    }
    return name[0..at];
}

/// `s` escaped at compile time.
fn escapedLiteral(comptime s: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10_000 + 100 * s.len);
        var buf: [escape.escapedLen(s)]u8 = undefined;
        var w: Writer = .fixed(&buf);
        escape.write(&w, s) catch unreachable;
        const final = buf;
        break :blk &final;
    };
}

fn writeFields(comptime f: Format, w: *Writer, fields: anytype, comptime cut: bool) Writer.Error!void {
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        // `.src` is the call site, never a field of the record.
        if (comptime std.mem.eql(u8, name, field_checks.source_field)) continue;
        const mark = w.end;
        const written = if (comptime redact.isSensitiveName(name))
            w.writeAll(comptime redactedField(f, name))
        else if (attrs.@"comptime" and comptime renderAtComptime(Field))
            w.writeAll(comptime literalField(f, name, @field(fields, name)))
        else
            writeField(f, w, name, @field(fields, name));
        written catch |e| {
            if (!cut) return e;
            w.end = mark; // leave this field out and try the next one
        };
    }
}

/// The longest level name records write.
const longest_level = blk: {
    var longest: usize = 0;
    for (std.enums.values(Level)) |level| longest = @max(longest, level.asText().len);
    break :blk longest;
};

/// The bytes every record needs, whatever it logs: the head with the
/// message cut down to "…", the longest level, a scope of `max_scope`
/// bytes (in quotes for text), the service fragment, the trace ids and the
/// cut closing. `Engine.create` rejects a smaller `max_record_bytes`.
pub fn mandatoryBytes(f: Format, service_len: usize, max_scope: usize) usize {
    return switch (f) {
        .json => "{\"timestamp\":\"".len + timestamp.len + "\",\"level\":\"".len + longest_level +
            "\",\"message\":\"".len + ellipsis.len + "\"".len + service_len +
            ",\"scope\":\"".len + max_scope + "\"".len + idsLen(.json) + closing(.json).cut.len,
        .text => timestamp.len + " ".len + 5 + " [\"".len + max_scope + "\"]".len +
            " ".len + ellipsis.len + idsLen(.text) + closing(.text).cut.len,
    };
}

/// Checks `value` in both formats.
fn expectValue(value: anytype, comptime json: []const u8, comptime text: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeValue(.json, &w, value);
    try testing.expectEqualStrings(json, w.buffered());
    w = .fixed(&buf);
    try writeValue(.text, &w, value);
    try testing.expectEqualStrings(text, w.buffered());
}

test "booleans and integers" {
    try expectValue(true, "true", "true");
    try expectValue(@as(u8, 255), "255", "255");
    try expectValue(@as(i64, std.math.minInt(i64)), "-9223372036854775808", "-9223372036854775808");
    try expectValue(@as(u64, std.math.maxInt(u64)), "18446744073709551615", "18446744073709551615");
    try expectValue(9000, "9000", "9000");
}

test "integers wider than 64 bits are JSON strings" {
    try expectValue(@as(u128, std.math.maxInt(u128)), "\"340282366920938463463374607431768211455\"", "340282366920938463463374607431768211455");
    try expectValue(@as(i128, std.math.minInt(i128)), "\"-170141183460469231731687303715884105728\"", "-170141183460469231731687303715884105728");
    try expectValue(1 << 70, "\"1180591620717411303424\"", "1180591620717411303424");
}

test "floats: the shortest form, an exponent outside 1e-6..1e21, specials as strings" {
    try expectValue(@as(f64, 1.5), "1.5", "1.5");
    try expectValue(@as(f32, 0.1), "0.1", "0.1");
    try expectValue(@as(f64, 1.0), "1", "1");
    try expectValue(@as(f64, -0.0), "-0", "-0");
    try expectValue(@as(f64, 1e300), "1e300", "1e300");
    try expectValue(@as(f64, 1e-7), "1e-7", "1e-7");
    try expectValue(@as(f128, 1e4000), "1e4000", "1e4000");
    try expectValue(@as(f16, 0.5), "0.5", "0.5");
    try expectValue(0.25, "0.25", "0.25");
    try expectValue(std.math.nan(f64), "\"NaN\"", "NaN");
    try expectValue(std.math.inf(f64), "\"+Inf\"", "+Inf");
    try expectValue(-std.math.inf(f64), "\"-Inf\"", "-Inf");
}

test "float literals keep their range and precision" {
    try expectValue(1e400, "1e400", "1e400");
    try expectValue(1e-400, "1e-400", "1e-400");
    try expectValue(1.0000000000000000001, "1.0000000000000000001", "1.0000000000000000001");
}

test "strings in every form" {
    try expectValue("admin", "\"admin\"", "admin");
    try expectValue("", "\"\"", "\"\"");
    try expectValue("a b", "\"a b\"", "\"a b\"");
    try expectValue("say \"hi\"\n", "\"say \\\"hi\\\"\\n\"", "\"say \\\"hi\\\"\\n\"");
    try expectValue("\xff", "\"\u{FFFD}\"", "\"\u{FFFD}\"");
    var slice: []const u8 = "slice";
    _ = &slice;
    try expectValue(slice, "\"slice\"", "slice");
    try expectValue([3]u8{ 'a', 'b', 'c' }, "\"abc\"", "abc");
    try expectValue(@as([*:0]const u8, "zed"), "\"zed\"", "zed");
    try expectValue(@as([:0]const u8, "zero"), "\"zero\"", "zero");
}

test "optionals and null" {
    try expectValue(@as(?u8, null), "null", "null");
    try expectValue(@as(?u8, 7), "7", "7");
    try expectValue(null, "null", "null");
    try expectValue(@as(?[]const u8, "x"), "\"x\"", "x");
}

test "enums and errors by name" {
    const Status = enum { active, banned };
    const Code = enum(u8) { ok, _ };
    const Odd = enum { @"two words" };
    try expectValue(Status.banned, "\"banned\"", "banned");
    try expectValue(@as(Code, @fromBackingInt(9)), "\"9\"", "9");
    try expectValue(.admin, "\"admin\"", "admin");
    try expectValue(Odd.@"two words", "\"two words\"", "\"two words\"");
    try expectValue(error.NotFound, "\"NotFound\"", "NotFound");
    var failure: anyerror = error.Timeout;
    _ = &failure;
    try expectValue(failure, "\"Timeout\"", "Timeout");
}

test "structs are objects in declaration order; void members are left out" {
    const Db = struct { host: []const u8, port: u16, nothing: void = {} };
    const Config = struct { name: []const u8, db: Db, empty: struct {} = .{} };
    try expectValue(
        Config{ .name = "svc", .db = .{ .host = "pg", .port = 5432 } },
        "{\"name\":\"svc\",\"db\":{\"host\":\"pg\",\"port\":5432},\"empty\":{}}",
        "{name=svc,db={host=pg,port=5432},empty={}}",
    );
    const Flags = packed struct { sampled: bool, random: bool, reserved: u6 };
    try expectValue(Flags{ .sampled = true, .random = false, .reserved = 0 }, "{\"sampled\":true,\"random\":false,\"reserved\":0}", "{sampled=true,random=false,reserved=0}");
}

test "tagged unions, arrays, slices, tuples, vectors and types" {
    const State = union(enum) { idle, running: u32 };
    try expectValue(State{ .running = 3 }, "{\"running\":3}", "{running=3}");
    try expectValue(@as(State, .idle), "{\"idle\":{}}", "{idle={}}");
    try expectValue([3]i32{ 1, -2, 3 }, "[1,-2,3]", "[1,-2,3]");
    var tags: []const []const u8 = &.{ "a", "b c", "d,e", "[x]" };
    _ = &tags;
    try expectValue(tags, "[\"a\",\"b c\",\"d,e\",\"[x]\"]", "[a,\"b c\",\"d,e\",\"[x]\"]");
    try expectValue(.{ 1, "two", true }, "[1,\"two\",true]", "[1,two,true]");
    try expectValue(@as(@Vector(3, u8), .{ 1, 2, 3 }), "[1,2,3]", "[1,2,3]");
    try expectValue(u8, "\"u8\"", "u8");
    try expectValue([]const u8, "\"[]const u8\"", "\"[]const u8\"");
}

test "pointers are followed; a pointer to an array is the array" {
    const Point = struct { x: i32, y: i32 };
    const p: Point = .{ .x = 1, .y = 2 };
    const arr = [2]u16{ 7, 8 };
    try expectValue(&p, "{\"x\":1,\"y\":2}", "{x=1,y=2}");
    try expectValue(@as(?*const Point, null), "null", "null");
    try expectValue(&arr, "[7,8]", "[7,8]");
}

test "containers nested deeper than 8 levels become [MAX_DEPTH]" {
    const Node = struct { v: u32, next: ?*const @This() };
    var nodes: [12]Node = undefined;
    for (&nodes, 0..) |*n, i| n.* = .{ .v = @intCast(i), .next = if (i + 1 < nodes.len) &nodes[i + 1] else null };
    inline for (.{ Format.json, Format.text }) |f| {
        var want: Writer.Allocating = .init(testing.allocator);
        defer want.deinit();
        for (0..8) |i| try want.writer.print(if (f == .json) "{{\"v\":{d},\"next\":" else "{{v={d},next=", .{i});
        try want.writer.writeAll(if (f == .json) "\"[MAX_DEPTH]\"" else "[MAX_DEPTH]");
        for (0..8) |_| try want.writer.writeByte('}');
        var buf: [1024]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try writeValue(f, &w, nodes[0]);
        try testing.expectEqualStrings(want.written(), w.buffered());
    }
}

test "redaction: a marked type and any wrapper around it give one placeholder; secret names at any depth" {
    const Key = struct {
        bytes: [4]u8,
        pub const zefir_sensitive = true;
    };
    const k: Key = .{ .bytes = "abcd".* };
    const keys = [_]Key{ k, k };
    const Config = struct {
        user: []const u8,
        key: Key,
        keys: []const Key,
        maybe: ?Key,
        db: struct { password: []const u8, host: []const u8 },
    };
    try expectValue(
        Config{ .user = "ada", .key = k, .keys = &keys, .maybe = null, .db = .{ .password = "hunter2", .host = "pg" } },
        "{\"user\":\"ada\",\"key\":\"[REDACTED]\",\"keys\":\"[REDACTED]\",\"maybe\":\"[REDACTED]\",\"db\":{\"password\":\"[REDACTED]\",\"host\":\"pg\"}}",
        "{user=ada,key=[REDACTED],keys=[REDACTED],maybe=[REDACTED],db={password=[REDACTED],host=pg}}",
    );
    const Auth = union(enum) { user: []const u8, api_key: []const u8 };
    try expectValue(Auth{ .api_key = "k" }, "{\"api_key\":\"[REDACTED]\"}", "{api_key=[REDACTED]}");
}

test "text spreads the objects of a field into dotted keys; arrays and optionals stay inline" {
    const Db = struct { host: []const u8, port: u16, password: []const u8 };
    const Config = struct { name: []const u8, db: Db, tags: []const []const u8, state: union(enum) { idle, running: u32 }, backup: ?Db };
    var cfg: Config = .{ .name = "svc", .db = .{ .host = "pg", .port = 5432, .password = "x" }, .tags = &.{"a"}, .state = .{ .running = 3 }, .backup = null };
    _ = &cfg;
    var buf: [512]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    const got = record(.text, .info, "Config", &buf, header, .{ .config = cfg, .self = &cfg.db }).?;
    try testing.expectEqualStrings("2026-10-10T21:08:00.123Z INFO  Config config.name=svc config.db.host=pg config.db.port=5432 config.db.password=[REDACTED] " ++
        "config.tags=[a] config.state.running=3 config.backup=null self.host=pg self.port=5432 self.password=[REDACTED]\n", buf[0..got.len]);
}

const Money = struct {
    cents: i64,
    pub fn format(m: Money, w: *Writer) Writer.Error!void {
        try w.print("{d}.{d:0>2} EUR", .{ @divTrunc(m.cents, 100), @abs(@rem(m.cents, 100)) });
    }
};

test "format: a type's own text, as a string" {
    try expectValue(Money{ .cents = 1999 }, "\"19.99 EUR\"", "\"19.99 EUR\"");
    const Code = struct {
        id: u32,
        pub fn format(c: *const @This(), w: *Writer) Writer.Error!void {
            try w.print("C-{d}", .{c.id});
        }
    };
    try expectValue(Code{ .id = 7 }, "\"C-7\"", "C-7");
    try expectValue([2]Code{ .{ .id = 1 }, .{ .id = 2 } }, "[\"C-1\",\"C-2\"]", "[C-1,C-2]");
    const Color = enum {
        red,
        pub fn format(c: @This(), w: *Writer) Writer.Error!void {
            try w.writeAll(if (c == .red) "#ff0000" else "?");
        }
    };
    try expectValue(Color.red, "\"#ff0000\"", "#ff0000");
}

test "format: whatever the method writes stays one valid line" {
    const Weird = struct {
        pub fn format(_: @This(), w: *Writer) Writer.Error!void {
            try w.writeAll("a\"b\nc\xff");
            try w.writeAll("\xe2\x82"); // a sequence split between two writes
            try w.writeAll("\xac,]");
        }
    };
    try expectValue(Weird{}, "\"a\\\"b\\nc\u{FFFD}€,]\"", "\"a\\\"b\\nc\u{FFFD}€,]\"");
    const Empty = struct {
        pub fn format(_: @This(), _: *Writer) Writer.Error!void {}
    };
    try expectValue(Empty{}, "\"\"", "\"\"");
}

test "logValue: the value the type logs instead of itself, under the same rules" {
    const Key = struct {
        raw: []const u8,
        pub const zefir_sensitive = true;
    };
    const User = struct {
        id: u64,
        password_hash: []const u8,
        key: Key,
        pub fn logValue(u: @This()) struct { id: u64, key: Key } {
            return .{ .id = u.id, .key = u.key };
        }
    };
    const user: User = .{ .id = 1, .password_hash = "x", .key = .{ .raw = "k" } };
    try expectValue(user, "{\"id\":1,\"key\":\"[REDACTED]\"}", "{id=1,key=[REDACTED]}");
    var buf: [256]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    var u = user;
    _ = &u;
    const got = record(.text, .info, "m", &buf, header, .{ .user = u }).?;
    try testing.expectStringEndsWith(buf[0..got.len], " m user.id=1 user.key=[REDACTED]\n");
}

test "the marker comes first, then logValue, then format, then the fields" {
    const MarkedFormat = struct {
        x: u8,
        pub const zefir_sensitive = true;
        pub fn format(_: @This(), w: *Writer) Writer.Error!void {
            try w.writeAll("leak");
        }
    };
    const Both = struct {
        x: u8,
        pub fn logValue(b: @This()) u8 {
            return b.x;
        }
        pub fn format(_: @This(), w: *Writer) Writer.Error!void {
            try w.writeAll("format");
        }
    };
    try expectValue(MarkedFormat{ .x = 1 }, "\"[REDACTED]\"", "[REDACTED]");
    try expectValue(Both{ .x = 5 }, "5", "5");
}

test "hex: bytes as lowercase hex" {
    const hex = @import("hex.zig").hex;
    const digest = [_]u8{ 0xde, 0xad, 0x00, 0x0f };
    try expectValue(hex(&digest), "\"dead000f\"", "dead000f");
}

test "literal nested values are rendered at compile time" {
    var buf: [256]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    const got = record(.json, .info, "m", &buf, header, .{ .cfg = .{ .a = 1, .kind = .admin, .list = .{ 1, "two" } } }).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"cfg\":{\"a\":1,\"kind\":\"admin\",\"list\":[1,\"two\"]}}\n");
}

var global_name: [4]u8 = "abcd".*;
var global_point: struct { x: i32 } = .{ .x = 1 };

test "a field that points to a global variable is read when the record is written" {
    global_name = "wxyz".*;
    global_point.x = 42;
    var buf: [256]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    const got = record(.json, .info, "m", &buf, header, .{ .name = &global_name, .point = &global_point }).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"name\":\"wxyz\",\"point\":{\"x\":42}}\n");
}

test "a literal field renders to the bytes a runtime one writes" {
    var port: u16 = 9000;
    _ = &port;
    inline for (.{ Format.json, Format.text }) |f| {
        var buf: [64]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try writeField(f, &w, "port", port);
        try testing.expectEqualStrings(w.buffered(), comptime literalField(f, "port", 9000));
    }
    try testing.expectEqualStrings(",\"port\":9000", comptime literalField(.json, "port", 9000));
    try testing.expectEqualStrings(" kind=admin", comptime literalField(.text, "kind", .admin));
    try testing.expectEqualStrings(",\"ratio\":0.25", comptime literalField(.json, "ratio", 0.25));
}

test "a redacted field hides its value in both formats" {
    try testing.expectEqualStrings(",\"password\":\"[REDACTED]\"", comptime redactedField(.json, "password"));
    try testing.expectEqualStrings(" password=[REDACTED]", comptime redactedField(.text, "password"));
}

/// 2026-10-10T21:08:00.123Z
const fixed_time: std.Io.Timestamp = .{ .nanoseconds = 1_791_666_480_123 * std.time.ns_per_ms };

/// Trace ids for the tests that cover the whole head.
const test_trace: TraceHex = .{ .trace_id = "4bf92f3577b34da6a3ce929d0e0e4736".*, .span_id = "00f067aa0ba902b7".* };

/// 20 000 bytes of 'é': far longer than any record.
const long_message = blk: {
    @setEvalBranchQuota(100_000);
    var bytes: [20_000]u8 = undefined;
    for (0..10_000) |i| {
        bytes[2 * i] = 0xc3;
        bytes[2 * i + 1] = 0xa9;
    }
    const final = bytes;
    break :blk &final;
};

test "a JSON record: metadata, then the fields in declaration order" {
    var buf: [512]u8 = undefined;
    var email: []const u8 = "ada@example.com";
    _ = &email;
    const here = comptime callSite();
    const got = record(.json, .info, "User created", &buf, .{
        .timestamp = fixed_time,
        .service = ",\"service.name\":\"user-service\"",
        .scope = "users",
        .oversize = .truncate,
    }, .{ .user_id = 42, .email = email, .password = "hunter2", .src = here }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{\"timestamp\":\"2026-10-10T21:08:00.123Z\",\"level\":\"info\",\"message\":\"User created\"," ++
        "\"service.name\":\"user-service\",\"scope\":\"users\",\"source\":{\"file\":\"encode.zig\",\"line\":" ++ std.fmt.comptimePrint("{d}", .{here.line}) ++
        "},\"user_id\":42,\"email\":\"ada@example.com\",\"password\":\"[REDACTED]\"}\n", buf[0..got.len]);
    try testing.expect(!got.truncated);
}

test "a text record: time, level, scope, message, then the fields" {
    var buf: [512]u8 = undefined;
    const got = record(.text, .err, "Payment failed", &buf, .{
        .timestamp = fixed_time,
        .service = "",
        .scope = "billing",
        .oversize = .truncate,
    }, .{ .order_id = 1001, .reason = "card declined", .password = "x" }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("2026-10-10T21:08:00.123Z ERROR [billing] Payment failed order_id=1001 reason=\"card declined\" password=[REDACTED]\n", buf[0..got.len]);
}

/// A call site with a known function name.
fn callSite() std.lang.SourceLocation {
    return @src();
}

test "the call site: after the scope in JSON, last in text; the mode picks the detail" {
    const here = comptime callSite();
    const line = std.fmt.comptimePrint("{d}", .{here.line});
    const column = std.fmt.comptimePrint("{d}", .{here.column});
    var buf: [512]u8 = undefined;
    var header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "users", .oversize = .truncate };
    var got = record(.json, .info, "m", &buf, header, .{ .src = here, .n = 1 }).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"scope\":\"users\",\"source\":{\"file\":\"encode.zig\",\"line\":" ++ line ++ "},\"n\":1}\n");
    got = record(.text, .info, "m", &buf, header, .{ .src = here, .n = 1 }).?;
    try testing.expectStringEndsWith(buf[0..got.len], " [users] m n=1 src=encode.zig:" ++ line ++ "\n");
    header.source = .full;
    got = record(.json, .info, "m", &buf, header, .{ .src = here }).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"source\":{\"file\":\"encode.zig\",\"line\":" ++ line ++ ",\"column\":" ++ column ++
        ",\"function\":\"callSite\",\"module\":\"" ++ here.module ++ "\"}}\n");
    got = record(.text, .info, "m", &buf, header, .{ .src = here }).?;
    try testing.expectStringEndsWith(buf[0..got.len], " src=encode.zig:" ++ line ++ ":" ++ column ++ " function=callSite module=" ++ here.module ++ "\n");
    header.source = .none;
    got = record(.json, .info, "m", &buf, header, .{ .src = here }).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"scope\":\"users\"}\n");
}

test "a call site known only at run time is written the same way" {
    var here = @src();
    _ = &here;
    var buf: [512]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    const got = record(.json, .warn, "m", &buf, header, .{ .src = here }).?;
    var want: [128]u8 = undefined;
    try testing.expectStringEndsWith(buf[0..got.len], try std.fmt.bufPrint(&want, ",\"source\":{{\"file\":\"encode.zig\",\"line\":{d}}}}}\n", .{here.line}));
}

test "generic functions lose their __func_N suffix" {
    try testing.expectEqualStrings("parse", functionName("parse__func_1234"));
    try testing.expectEqualStrings("parse", functionName("parse"));
    try testing.expectEqualStrings("my__func_x", functionName("my__func_x"));
}

test "a call site that does not fit gives way before the message does" {
    const here = @src();
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    var whole_buf: [512]u8 = undefined;
    const without = record(.json, .info, "a long message that has to be cut", &whole_buf, header, .{}).?;
    var buf: [512]u8 = undefined;
    // Room for the message cut down to a few characters, not for the source.
    const got = record(.json, .info, "a long message that has to be cut", buf[0 .. without.len - 10], header, .{ .src = here }).?;
    try testing.expect(got.truncated);
    try testing.expect(std.mem.find(u8, buf[0..got.len], "source") == null);
    try testing.expect(try std.json.validate(testing.allocator, buf[0..got.len]));
    inline for (.{ Format.json, Format.text }) |f| {
        var full: [512]u8 = undefined;
        const whole = record(f, .info, "m", &full, header, .{ .src = here, .note = "some words to drop" }).?;
        var size = mandatoryBytes(f, 0, 0);
        while (size <= whole.len) : (size += 1) {
            const cut = record(f, .info, "m", buf[0..size], header, .{ .src = here, .note = "some words to drop" }) orelse return error.TestUnexpectedResult;
            if (f == .json) try testing.expect(try std.json.validate(testing.allocator, buf[0..cut.len]));
        }
    }
}

test "a text scope marked for quotes is written in quotes; JSON ignores the mark" {
    var buf: [256]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "a] fake=1 [b", .scope_quoted = true, .oversize = .truncate };
    var got = record(.text, .info, "m", &buf, header, .{}).?;
    try testing.expectEqualStrings("2026-10-10T21:08:00.123Z INFO  [\"a] fake=1 [b\"] m\n", buf[0..got.len]);
    got = record(.json, .info, "m", &buf, header, .{}).?;
    try testing.expectStringEndsWith(buf[0..got.len], ",\"scope\":\"a] fake=1 [b\"}\n");
}

test "no scope, no fields and an empty text message leave no gaps" {
    var buf: [256]u8 = undefined;
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    var got = record(.json, .warn, "Disk low", &buf, header, .{}).?;
    try testing.expectEqualStrings("{\"timestamp\":\"2026-10-10T21:08:00.123Z\",\"level\":\"warn\",\"message\":\"Disk low\"}\n", buf[0..got.len]);
    got = record(.text, .info, "", &buf, header, .{ .n = 1 }).?;
    try testing.expectEqualStrings("2026-10-10T21:08:00.123Z INFO  n=1\n", buf[0..got.len]);
}

test "a record that fits exactly is written whole; one byte less cuts it" {
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "users", .oversize = .truncate };
    const fields = .{ .user_id = 42, .note = "a note that is long enough to drop" };
    var whole_buf: [512]u8 = undefined;
    const whole = record(.json, .info, "User created", &whole_buf, header, fields).?;
    var buf: [512]u8 = undefined;
    const exact = record(.json, .info, "User created", buf[0..whole.len], header, fields).?;
    try testing.expect(!exact.truncated);
    try testing.expectEqualStrings(whole_buf[0..whole.len], buf[0..exact.len]);
    const short = record(.json, .info, "User created", buf[0 .. whole.len - 1], header, fields).?;
    try testing.expect(short.truncated);
    try testing.expectStringEndsWith(buf[0..short.len], ",\"user_id\":42,\"truncated\":true}\n");
    var drop = header;
    drop.oversize = .drop;
    try testing.expect(record(.json, .info, "User created", buf[0 .. whole.len - 1], drop, fields) == null);
}

test "runtime fields: a record that fits exactly is written whole in both formats" {
    const Status = enum { active, banned };
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "users", .oversize = .truncate };
    var n: u64 = 18446744073709551615;
    var big: i128 = -170141183460469231731687303715884105728;
    var ratio: f64 = 0.125;
    var small: f32 = 0.1;
    var status: Status = .banned;
    var failure: anyerror = error.Timeout;
    var maybe: ?u16 = null;
    var text: []const u8 = "a value with spaces";
    _ = .{ &n, &big, &ratio, &small, &status, &failure, &maybe, &text };
    const fields = .{ .n = n, .big = big, .ratio = ratio, .small = small, .status = status, .failure = failure, .maybe = maybe, .text = text };
    inline for (.{ Format.json, Format.text }) |f| {
        var whole_buf: [512]u8 = undefined;
        const whole = record(f, .info, "Runtime", &whole_buf, header, fields).?;
        try testing.expect(!whole.truncated);
        var buf: [512]u8 = undefined;
        const exact = record(f, .info, "Runtime", buf[0..whole.len], header, fields).?;
        try testing.expect(!exact.truncated);
        try testing.expectEqualStrings(whole_buf[0..whole.len], buf[0..exact.len]);
        const short = record(f, .info, "Runtime", buf[0 .. whole.len - 1], header, fields).?;
        try testing.expect(short.truncated);
        if (f == .json) try testing.expect(try std.json.validate(testing.allocator, buf[0..short.len]));
    }
}

test "every size from the mandatory part up gives one valid line" {
    const header: Header = .{ .timestamp = fixed_time, .service = ",\"service.name\":\"svc\"", .scope = "users", .trace = &test_trace, .oversize = .truncate };
    const message = "User \"créé\" 😀 with a fairly long message";
    var detail: []const u8 = "0123456789€0123456789";
    _ = &detail;
    const fields = .{ .user_id = 42, .detail = detail, .ok = true, .ratio = 0.5 };
    inline for (.{ Format.json, Format.text }) |f| {
        var whole_buf: [1024]u8 = undefined;
        const whole = record(f, .warn, message, &whole_buf, header, fields).?;
        var size = mandatoryBytes(f, header.service.len, header.scope.len);
        while (size <= whole.len) : (size += 1) {
            var buf: [1024]u8 = undefined;
            const got = record(f, .warn, message, buf[0..size], header, fields) orelse return error.TestUnexpectedResult;
            const line = buf[0..got.len];
            try testing.expectEqual(size < whole.len, got.truncated);
            try testing.expect(std.unicode.utf8ValidateSlice(line));
            try testing.expectEqual(@as(?usize, line.len - 1), std.mem.findScalar(u8, line, '\n'));
            if (f == .json) try testing.expect(try std.json.validate(testing.allocator, line));
        }
    }
}

test "nested fields: every size from the mandatory part up gives one valid line" {
    const header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "users", .trace = &test_trace, .oversize = .truncate };
    const Db = struct { host: []const u8, ports: []const u16 };
    var db: Db = .{ .host = "pg \"main\"", .ports = &.{ 5432, 5433 } };
    _ = &db;
    const State = union(enum) { idle, running: u32 };
    const fields = .{ .db = db, .list = .{ 1, "two" }, .state = State{ .running = 3 } };
    inline for (.{ Format.json, Format.text }) |f| {
        var whole_buf: [1024]u8 = undefined;
        const whole = record(f, .info, "Nested", &whole_buf, header, fields).?;
        var size = mandatoryBytes(f, 0, header.scope.len);
        while (size <= whole.len) : (size += 1) {
            var buf: [1024]u8 = undefined;
            const got = record(f, .info, "Nested", buf[0..size], header, fields) orelse return error.TestUnexpectedResult;
            const line = buf[0..got.len];
            try testing.expectEqual(size < whole.len, got.truncated);
            try testing.expectEqual(@as(?usize, line.len - 1), std.mem.findScalar(u8, line, '\n'));
            if (f == .json) try testing.expect(try std.json.validate(testing.allocator, line));
        }
    }
}

test "a message longer than the record is cut between characters" {
    var buf: [4096]u8 = undefined;
    var header: Header = .{ .timestamp = fixed_time, .service = "", .scope = "", .oversize = .truncate };
    const got = record(.json, .info, long_message, &buf, header, .{ .id = 1 }).?;
    const line = buf[0..got.len];
    try testing.expect(got.truncated);
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expect(try std.json.validate(testing.allocator, line));
    try testing.expectStringEndsWith(line, "é…\",\"truncated\":true}\n");
    header.oversize = .drop;
    try testing.expect(record(.json, .info, long_message, &buf, header, .{}) == null);
}

test "mandatoryBytes holds the worst head: the longest level, the longest scope, the service and the trace ids" {
    const scope = &@as([128]u8, @splat('s'));
    const service = ",\"service.name\":\"" ++ &@as([100]u8, @splat('v')) ++ "\"";
    inline for (.{ Format.json, Format.text }) |f| {
        // A text scope that needs quotes is the longest one.
        const header: Header = .{ .timestamp = fixed_time, .service = if (f == .json) service else "", .scope = scope, .scope_quoted = f == .text, .trace = &test_trace, .oversize = .truncate };
        var buf: [2048]u8 = undefined;
        const size = mandatoryBytes(f, header.service.len, 128);
        const got = record(f, .err, "A message that cannot fit", buf[0..size], header, .{ .id = 1 }) orelse return error.TestUnexpectedResult;
        try testing.expect(got.truncated);
        if (f == .json) try testing.expect(try std.json.validate(testing.allocator, buf[0..got.len]));
    }
}
