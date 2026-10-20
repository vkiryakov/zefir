//! Relaxed Extended JSON, the text MongoDB's tools print documents in,
//! for logs and test messages: `{f}` of `RawDocument`. Numbers print as
//! JSON numbers where they can, other types as objects with a `$` key,
//! such as {"$oid": "…"} and {"$date": "…"}. The output is compact and
//! valid JSON: strings and keys are escaped, and bytes that are not UTF-8
//! print as U+FFFD.

const std = @import("std");
const bson = @import("../bson.zig");
const Writer = std.Io.Writer;

/// What a document that is not valid BSON prints as.
pub const invalid = "<invalid BSON>";

/// Writes `doc`, or `invalid` if `doc.validate` fails. Walks with a stack
/// of its own rather than recursion.
pub fn writeDocument(w: *Writer, doc: bson.RawDocument) Writer.Error!void {
    doc.validate() catch return w.writeAll(invalid);
    const Frame = struct {
        it: bson.RawDocument.Iterator,
        array: bool,
        /// What ends this document: "}" or "]", or "}}" for the scope of
        /// a code with scope, which ends its object too.
        close: []const u8,
        count: usize = 0,
    };
    var stack: [bson.max_depth]Frame = undefined;
    stack[0] = .{ .it = doc.iterator(), .array = false, .close = "}" };
    var depth: usize = 1;
    try w.writeByte('{');
    while (depth > 0) {
        const frame = &stack[depth - 1];
        // validate has checked every element: the errors cannot come.
        const element = (frame.it.next() catch return w.writeAll(invalid)) orelse {
            try w.writeAll(frame.close);
            depth -= 1;
            continue;
        };
        if (frame.count > 0) try w.writeByte(',');
        frame.count += 1;
        if (!frame.array) {
            try writeString(w, element.key);
            try w.writeByte(':');
        }
        const inner: Frame = switch (element.value) {
            .document => |d| .{ .it = d.iterator(), .array = false, .close = "}" },
            .array => |d| .{ .it = d.iterator(), .array = true, .close = "]" },
            .javascript_with_scope => |code| scope: {
                try w.writeAll("{\"$code\":");
                try writeString(w, code.code);
                try w.writeAll(",\"$scope\":");
                break :scope .{ .it = code.scope.iterator(), .array = false, .close = "}}" };
            },
            else => {
                try writeScalar(w, element.value);
                continue;
            },
        };
        if (depth == stack.len) return w.writeAll(invalid);
        try w.writeByte(if (inner.array) '[' else '{');
        stack[depth] = inner;
        depth += 1;
    }
}

/// Writes a value that holds no document.
fn writeScalar(w: *Writer, value: bson.Value) Writer.Error!void {
    switch (value) {
        .double => |d| try writeDouble(w, d),
        .string => |s| try writeString(w, s),
        .binary => |binary| {
            try w.writeAll("{\"$binary\":{\"base64\":\"");
            try std.base64.standard.Encoder.encodeWriter(w, binary.bytes);
            try w.print("\",\"subType\":\"{x:0>2}\"", .{@backingInt(binary.subtype)});
            try w.writeAll("}}");
        },
        .undefined => try w.writeAll("{\"$undefined\":true}"),
        .object_id => |id| try writeObjectId(w, id),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .date_time => |t| try writeDate(w, t.milliseconds),
        .null => try w.writeAll("null"),
        .regex => |regex| {
            try w.writeAll("{\"$regularExpression\":{\"pattern\":");
            try writeString(w, regex.pattern);
            try w.writeAll(",\"options\":");
            try writeString(w, regex.options);
            try w.writeAll("}}");
        },
        .db_pointer => |pointer| {
            try w.writeAll("{\"$dbPointer\":{\"$ref\":");
            try writeString(w, pointer.namespace);
            try w.writeAll(",\"$id\":");
            try writeObjectId(w, pointer.id);
            try w.writeAll("}}");
        },
        .javascript => |code| {
            try w.writeAll("{\"$code\":");
            try writeString(w, code);
            try w.writeByte('}');
        },
        .symbol => |symbol| {
            try w.writeAll("{\"$symbol\":");
            try writeString(w, symbol);
            try w.writeByte('}');
        },
        .int32 => |n| try w.print("{d}", .{n}),
        .timestamp => |t| {
            try w.print("{{\"$timestamp\":{{\"t\":{d},\"i\":{d}", .{ t.seconds, t.increment });
            try w.writeAll("}}");
        },
        .int64 => |n| try w.print("{d}", .{n}),
        .decimal128 => |d| try w.print("{{\"$numberDecimal\":\"{f}\"}}", .{d}),
        .min_key => try w.writeAll("{\"$minKey\":1}"),
        .max_key => try w.writeAll("{\"$maxKey\":1}"),
        // writeDocument walks these itself.
        .document, .array, .javascript_with_scope => try w.writeAll(invalid),
    }
}

fn writeObjectId(w: *Writer, id: bson.ObjectId) Writer.Error!void {
    try w.print("{{\"$oid\":\"{f}\"}}", .{id});
}

/// A finite double prints as the shortest JSON number that reads back as
/// it, with a point or an exponent, so that it reads as a double: 1.0,
/// 2.5, 1e300. NaN and the infinities have no JSON number.
fn writeDouble(w: *Writer, d: f64) Writer.Error!void {
    if (std.math.isNan(d)) return w.writeAll("{\"$numberDouble\":\"NaN\"}");
    if (std.math.isInf(d)) return w.writeAll(if (d > 0) "{\"$numberDouble\":\"Infinity\"}" else "{\"$numberDouble\":\"-Infinity\"}");
    const magnitude = @abs(d);
    if (magnitude != 0 and (magnitude < 1e-6 or magnitude >= 1e21)) return w.print("{e}", .{d});
    var buffer: [32]u8 = undefined;
    // Below 1e21 the digits fit: at most 21 before the point, and the
    // shortest round trip needs at most 17 significant digits.
    const text = std.fmt.bufPrint(&buffer, "{d}", .{d}) catch return w.print("{e}", .{d});
    try w.writeAll(text);
    if (std.mem.findScalar(u8, text, '.') == null) try w.writeAll(".0");
}

/// Milliseconds from 1970 through 9999 print as an ISO-8601 instant in
/// UTC, with the milliseconds if there are any; others as their number.
fn writeDate(w: *Writer, milliseconds: i64) Writer.Error!void {
    // 9999-12-31T23:59:59.999Z
    const last = 253402300799999;
    if (milliseconds < 0 or milliseconds > last) {
        return w.print("{{\"$date\":{{\"$numberLong\":\"{d}\"}}}}", .{milliseconds});
    }
    const ms: u64 = @intCast(milliseconds);
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    try w.print("{{\"$date\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
    if (ms % 1000 != 0) try w.print(".{d:0>3}", .{ms % 1000});
    try w.writeAll("Z\"}");
}

/// Writes `s` as a JSON string: quotes, backslashes and control bytes are
/// escaped, UTF-8 is copied, and each byte that is not UTF-8 prints as
/// U+FFFD.
fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        // Copy the run of bytes that need nothing done at once.
        const plain = i;
        while (i < s.len and s[i] >= 0x20 and s[i] < 0x7f and s[i] != '"' and s[i] != '\\') i += 1;
        try w.writeAll(s[plain..i]);
        if (i == s.len) break;
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
            else => {
                const n = utf8Length(s[i..]);
                if (n == 0) {
                    try w.writeAll("\\ufffd");
                    i += 1;
                } else {
                    try w.writeAll(s[i..][0..n]);
                    i += n;
                }
                continue;
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}

/// The length of the UTF-8 character at the start of `bytes`, or 0 if
/// they do not start with one.
fn utf8Length(bytes: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 0;
    if (n > bytes.len) return 0;
    _ = std.unicode.utf8Decode(bytes[0..n]) catch return 0;
    return n;
}
