//! Encodes records as JSON Lines or text into a caller's buffer. The
//! message, the keys and literal field values are rendered at compile
//! time; at run time only the timestamp, the scope and runtime values are
//! written.

const std = @import("std");
const escape = @import("escape.zig");
const field_checks = @import("fields.zig");
const redact = @import("redact.zig");
const options = @import("options.zig");

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
        .comptime_float => try writeFloat(f, w, @as(f64, value)),
        .null => try w.writeAll("null"),
        .optional => if (value) |payload| try writeValue(f, w, payload) else try w.writeAll("null"),
        .@"enum" => if (std.enums.tagName(T, value)) |name|
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
