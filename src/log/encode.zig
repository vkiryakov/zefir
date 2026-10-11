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

/// Writes one value. Values known only at compile time (`comptime_int`,
/// enum literals, `null`) are written at compile time, see `literalField`.
fn writeValue(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime field_checks.isString(T)) {
        const s: []const u8 = switch (@typeInfo(T)) {
            .array => &value,
            .pointer => |p| switch (p.size) {
                .slice, .one => value,
                .many => std.mem.span(value),
                .c => unreachable,
            },
            else => unreachable,
        };
        return writeString(f, w, s);
    }
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
        .optional => if (value) |payload| try writeValue(f, w, payload) else try w.writeAll("null"),
        // Every value of an exhaustive enum has a name: one table lookup.
        .@"enum" => |e| if (e.mode == .exhaustive)
            try writeString(f, w, @tagName(value))
        else if (std.enums.tagName(T, value)) |name|
            try writeString(f, w, name)
        else
            try writeQuotedDigits(f, w, @backingInt(value)),
        .enum_literal => try writeString(f, w, @tagName(value)),
        .error_set => try writeString(f, w, @errorName(value)),
        else => @compileError("unreachable: fields.check lets no other type through"),
    }
}

fn writeString(comptime f: Format, w: *Writer, s: []const u8) Writer.Error!void {
    if (f == .text and escape.isBare(s)) return w.writeAll(s);
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

/// The separator and the key: `,"name":` or ` name=`. Field names are
/// limited to [A-Za-z0-9_.-], so they never need escaping.
fn key(comptime f: Format, comptime name: []const u8) []const u8 {
    return switch (f) {
        .json => ",\"" ++ name ++ "\":",
        .text => " " ++ name ++ "=",
    };
}

fn writeField(comptime f: Format, w: *Writer, comptime name: []const u8, value: anytype) Writer.Error!void {
    try w.writeAll(comptime key(f, name));
    try writeValue(f, w, value);
}

/// A field whose value is known at compile time, rendered once: at run
/// time it costs one copy.
fn literalField(comptime f: Format, comptime name: []const u8, comptime value: anytype) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var counter: Writer.Discarding = .init(&.{});
        writeField(f, &counter.writer, name, value) catch unreachable;
        var buf: [@intCast(counter.count + counter.writer.end)]u8 = undefined;
        var w: Writer = .fixed(&buf);
        writeField(f, &w, name, value) catch unreachable;
        const final = buf;
        break :blk &final;
    };
}

fn redactedField(comptime f: Format, comptime name: []const u8) []const u8 {
    return key(f, name) ++ switch (f) {
        .json => "\"" ++ redact.placeholder ++ "\"",
        .text => redact.placeholder,
    };
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
    oversize: options.OversizePolicy,
};

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
/// its end, fields that do not fit are left out, and the record ends with
/// the truncation marker) or not written at all (`.drop`: null).
pub fn record(
    comptime f: Format,
    comptime level: Level,
    comptime message: []const u8,
    out: []u8,
    header: Header,
    fields: anytype,
) ?Encoded {
    var stamp: [timestamp.len]u8 = undefined;
    timestamp.format(header.timestamp, &stamp);
    if (encode(f, level, message, out, header, &stamp, fields, false)) |len| return .{ .len = len, .truncated = false };
    if (header.oversize == .drop) return null;
    const len = encode(f, level, message, out, header, &stamp, fields, true) orelse return null;
    return .{ .len = len, .truncated = true };
}

/// One pass of `record`. Whole: everything must fit, else null. Cut: the
/// message and the fields give way, and the record ends with the
/// truncation marker.
fn encode(
    comptime f: Format,
    comptime level: Level,
    comptime message: []const u8,
    out: []u8,
    header: Header,
    stamp: *const [timestamp.len]u8,
    fields: anytype,
    comptime cut: bool,
) ?usize {
    const close = comptime if (cut) closing(f).cut else closing(f).whole;
    if (out.len < close.len) return null;
    var w: Writer = .fixed(out[0 .. out.len - close.len]);
    writeHead(f, level, message, &w, header, stamp, cut) catch return null;
    writeFields(f, &w, fields, cut) catch return null;
    @memcpy(out[w.end..][0..close.len], close);
    return w.end + close.len;
}

fn writeHead(
    comptime f: Format,
    comptime level: Level,
    comptime message: []const u8,
    w: *Writer,
    header: Header,
    stamp: *const [timestamp.len]u8,
    comptime cut: bool,
) Writer.Error!void {
    switch (f) {
        .json => {
            try w.writeAll("{\"timestamp\":\"");
            try w.writeAll(stamp);
            try w.writeAll(comptime "\",\"level\":\"" ++ level.asText() ++ "\",\"message\":\"");
            const scope_len = if (header.scope.len > 0) ",\"scope\":\"".len + header.scope.len + 1 else 0;
            try writeMessage(w, "", message, "\"", header.service.len + scope_len, cut);
            try w.writeAll(header.service);
            if (header.scope.len > 0) {
                try w.writeAll(",\"scope\":\"");
                try w.writeAll(header.scope);
                try w.writeByte('"');
            }
        },
        .text => {
            try w.writeAll(stamp);
            try w.writeAll(comptime " " ++ level.label());
            if (header.scope.len > 0) {
                try w.writeAll(if (header.scope_quoted) " [\"" else " [");
                try w.writeAll(header.scope);
                try w.writeAll(if (header.scope_quoted) "\"]" else "]");
            }
            if (message.len > 0) try writeMessage(w, " ", message, "", 0, cut);
        },
    }
}

/// Writes `open`, the escaped message and `close`, leaving `keep` bytes
/// for the rest of the head. In a cut pass a message that does not fit
/// loses its end, between characters, and ends with "…".
fn writeMessage(
    w: *Writer,
    comptime open: []const u8,
    comptime message: []const u8,
    comptime close: []const u8,
    keep: usize,
    comptime cut: bool,
) Writer.Error!void {
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
    inline for (info.field_names, info.field_attrs) |name, attrs| {
        // `.src` is the call site, never a field of the record.
        if (comptime std.mem.eql(u8, name, field_checks.source_field)) continue;
        const mark = w.end;
        const written = if (comptime redact.isSensitiveName(name))
            w.writeAll(comptime redactedField(f, name))
        else if (attrs.@"comptime")
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
/// bytes (in quotes for text), the service fragment and the cut closing.
/// `Engine.create` rejects a smaller `max_record_bytes`.
pub fn mandatoryBytes(f: Format, service_len: usize, max_scope: usize) usize {
    return switch (f) {
        .json => "{\"timestamp\":\"".len + timestamp.len + "\",\"level\":\"".len + longest_level +
            "\",\"message\":\"".len + ellipsis.len + "\"".len + service_len +
            ",\"scope\":\"".len + max_scope + "\"".len + closing(.json).cut.len,
        .text => timestamp.len + " ".len + 5 + " [\"".len + max_scope + "\"]".len +
            " ".len + ellipsis.len + closing(.text).cut.len,
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
    const got = record(.json, .info, "User created", &buf, .{
        .timestamp = fixed_time,
        .service = ",\"service.name\":\"user-service\"",
        .scope = "users",
        .oversize = .truncate,
    }, .{ .user_id = 42, .email = email, .password = "hunter2", .src = @src() }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{\"timestamp\":\"2026-10-10T21:08:00.123Z\",\"level\":\"info\",\"message\":\"User created\"," ++
        "\"service.name\":\"user-service\",\"scope\":\"users\",\"user_id\":42,\"email\":\"ada@example.com\",\"password\":\"[REDACTED]\"}\n", buf[0..got.len]);
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
    const header: Header = .{ .timestamp = fixed_time, .service = ",\"service.name\":\"svc\"", .scope = "users", .oversize = .truncate };
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

test "mandatoryBytes holds the worst head: the longest level, the longest scope and the service" {
    const scope = &@as([128]u8, @splat('s'));
    const service = ",\"service.name\":\"" ++ &@as([100]u8, @splat('v')) ++ "\"";
    inline for (.{ Format.json, Format.text }) |f| {
        // A text scope that needs quotes is the longest one.
        const header: Header = .{ .timestamp = fixed_time, .service = if (f == .json) service else "", .scope = scope, .scope_quoted = f == .text, .oversize = .truncate };
        var buf: [2048]u8 = undefined;
        const size = mandatoryBytes(f, header.service.len, 128);
        const got = record(f, .err, "A message that cannot fit", buf[0..size], header, .{ .id = 1 }) orelse return error.TestUnexpectedResult;
        try testing.expect(got.truncated);
        if (f == .json) try testing.expect(try std.json.validate(testing.allocator, buf[0..got.len]));
    }
}
