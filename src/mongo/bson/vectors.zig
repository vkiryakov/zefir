//! Test vectors of `mongo.bson`, written for zefir from the BSON spec
//! (https://bsonspec.org/spec.html). The bson-corpus of
//! mongodb/specifications is not used: its license does not fit zefir.
//!
//! `valid` holds a document {"a": value} for every BSON type, with the
//! value it reads back as; `broken` holds bytes that no reader may accept.

const std = @import("std");
const bson = @import("../bson.zig");
const Value = bson.Value;

/// A document of one element, "a".
pub const Vector = struct {
    name: []const u8,
    /// The whole document.
    bson: []const u8,
    /// What "a" reads back as.
    value: Value,
};

pub const object_id = hex("56e1fc72e0c917e9c4714161").*;
const uuid = hex("73ffd26444b34c6990e8e7d1dfc035d4");

pub const valid = [_]Vector{
    .{ .name = "double 1.0", .bson = hex("10000000 01 6100 000000000000f03f 00"), .value = .{ .double = 1.0 } },
    .{ .name = "double -0.0", .bson = hex("10000000 01 6100 0000000000000080 00"), .value = .{ .double = -0.0 } },
    .{ .name = "double 2.5", .bson = hex("10000000 01 6100 0000000000000440 00"), .value = .{ .double = 2.5 } },
    .{ .name = "double 1e300", .bson = hex("10000000 01 6100 9c7500883ce4377e 00"), .value = .{ .double = 1e300 } },
    .{ .name = "double NaN", .bson = hex("10000000 01 6100 000000000000f87f 00"), .value = .{ .double = std.math.nan(f64) } },
    .{ .name = "double +inf", .bson = hex("10000000 01 6100 000000000000f07f 00"), .value = .{ .double = std.math.inf(f64) } },
    .{ .name = "double -inf", .bson = hex("10000000 01 6100 000000000000f0ff 00"), .value = .{ .double = -std.math.inf(f64) } },
    .{ .name = "string", .bson = hex("10000000 02 6100 04000000 416e6e00 00"), .value = .{ .string = "Ann" } },
    .{ .name = "empty string", .bson = hex("0d000000 02 6100 01000000 00 00"), .value = .{ .string = "" } },
    .{ .name = "string in Cyrillic", .bson = hex("19000000 02 6100 0d000000 d09fd180d0b8d0b2d0b5d182 00 00"), .value = .{ .string = "Привет" } },
    .{ .name = "string with a NUL", .bson = hex("10000000 02 6100 04000000 61006200 00"), .value = .{ .string = "a\x00b" } },
    .{ .name = "document", .bson = hex("14000000 03 6100 0c000000 10 6200 01000000 00 00"), .value = .{ .document = .{ .bytes = hex("0c000000 10 6200 01000000 00") } } },
    .{ .name = "empty document", .bson = hex("0d000000 03 6100 05000000 00 00"), .value = .{ .document = .{ .bytes = hex("05000000 00") } } },
    .{
        .name = "array",
        .bson = hex("1d000000 04 6100 15000000 10 3000 01000000 02 3100 02000000 7800 00 00"),
        .value = .{ .array = .{ .bytes = hex("15000000 10 3000 01000000 02 3100 02000000 7800 00") } },
    },
    .{ .name = "empty array", .bson = hex("0d000000 04 6100 05000000 00 00"), .value = .{ .array = .{ .bytes = hex("05000000 00") } } },
    .{ .name = "binary", .bson = hex("10000000 05 6100 03000000 00 010203 00"), .value = .{ .binary = .{ .subtype = .generic, .bytes = &.{ 1, 2, 3 } } } },
    .{ .name = "binary UUID", .bson = hex("1d000000 05 6100 10000000 04 73ffd26444b34c6990e8e7d1dfc035d4 00"), .value = .{ .binary = .{ .subtype = .uuid, .bytes = uuid } } },
    // The old binary subtype keeps a second length inside the data; the
    // value is the data after it.
    .{ .name = "binary of the old subtype", .bson = hex("13000000 05 6100 06000000 02 02000000 ffff 00"), .value = .{ .binary = .{ .subtype = .binary_old, .bytes = &.{ 0xff, 0xff } } } },
    .{ .name = "empty user-defined binary", .bson = hex("0d000000 05 6100 00000000 80 00"), .value = .{ .binary = .{ .subtype = .user_defined, .bytes = "" } } },
    .{ .name = "undefined", .bson = hex("08000000 06 6100 00"), .value = .undefined },
    .{ .name = "ObjectId", .bson = hex("14000000 07 6100 56e1fc72e0c917e9c4714161 00"), .value = .{ .object_id = .{ .bytes = object_id } } },
    .{ .name = "true", .bson = hex("09000000 08 6100 01 00"), .value = .{ .boolean = true } },
    .{ .name = "false", .bson = hex("09000000 08 6100 00 00"), .value = .{ .boolean = false } },
    .{ .name = "datetime at the epoch", .bson = hex("10000000 09 6100 0000000000000000 00"), .value = .{ .date_time = .{ .milliseconds = 0 } } },
    .{ .name = "datetime with milliseconds", .bson = hex("10000000 09 6100 c5d8d6cc3b010000 00"), .value = .{ .date_time = .{ .milliseconds = 1356351330501 } } },
    .{ .name = "datetime before the epoch", .bson = hex("10000000 09 6100 ffffffffffffffff 00"), .value = .{ .date_time = .{ .milliseconds = -1 } } },
    .{ .name = "datetime in the year 10000", .bson = hex("10000000 09 6100 00dc1fd277e60000 00"), .value = .{ .date_time = .{ .milliseconds = 253402300800000 } } },
    .{ .name = "null", .bson = hex("08000000 0a 6100 00"), .value = .null },
    .{ .name = "regular expression", .bson = hex("10000000 0b 6100 5e612e6300 696d00 00"), .value = .{ .regex = .{ .pattern = "^a.c", .options = "im" } } },
    .{ .name = "empty regular expression", .bson = hex("0a000000 0b 6100 00 00 00"), .value = .{ .regex = .{ .pattern = "", .options = "" } } },
    .{
        .name = "DBPointer",
        .bson = hex("1a000000 0c 6100 02000000 6200 56e1fc72e0c917e9c4714161 00"),
        .value = .{ .db_pointer = .{ .namespace = "b", .id = .{ .bytes = object_id } } },
    },
    .{ .name = "JavaScript", .bson = hex("10000000 0d 6100 04000000 783d3100 00"), .value = .{ .javascript = "x=1" } },
    .{ .name = "symbol", .bson = hex("0e000000 0e 6100 02000000 7300 00"), .value = .{ .symbol = "s" } },
    .{
        .name = "JavaScript with scope",
        .bson = hex("1e000000 0f 6100 16000000 02000000 7800 0c000000 10 7800 01000000 00 00"),
        .value = .{ .javascript_with_scope = .{ .code = "x", .scope = .{ .bytes = hex("0c000000 10 7800 01000000 00") } } },
    },
    .{ .name = "int32", .bson = hex("0c000000 10 6100 01000000 00"), .value = .{ .int32 = 1 } },
    .{ .name = "smallest int32", .bson = hex("0c000000 10 6100 00000080 00"), .value = .{ .int32 = std.math.minInt(i32) } },
    .{ .name = "largest int32", .bson = hex("0c000000 10 6100 ffffff7f 00"), .value = .{ .int32 = std.math.maxInt(i32) } },
    // The increment comes first: the low 32 bits of the uint64.
    .{ .name = "timestamp", .bson = hex("10000000 11 6100 2a000000 15cd5b07 00"), .value = .{ .timestamp = .{ .seconds = 123456789, .increment = 42 } } },
    .{ .name = "int64", .bson = hex("10000000 12 6100 0100000000000000 00"), .value = .{ .int64 = 1 } },
    .{ .name = "int64 beyond int32", .bson = hex("10000000 12 6100 005ed0b200000000 00"), .value = .{ .int64 = 3_000_000_000 } },
    .{ .name = "largest int64", .bson = hex("10000000 12 6100 ffffffffffffff7f 00"), .value = .{ .int64 = std.math.maxInt(i64) } },
    .{ .name = "smallest int64", .bson = hex("10000000 12 6100 0000000000000080 00"), .value = .{ .int64 = std.math.minInt(i64) } },
    .{ .name = "Decimal128", .bson = hex("18000000 13 6100 0f000000000000000000000000003e30 00"), .value = .{ .decimal128 = .{ .bytes = hex("0f000000000000000000000000003e30").* } } },
    .{ .name = "MinKey", .bson = hex("08000000 ff 6100 00"), .value = .min_key },
    .{ .name = "MaxKey", .bson = hex("08000000 7f 6100 00"), .value = .max_key },
};

/// {}
pub const empty = hex("05000000 00");

/// A reply of find:
/// {"cursor": {"firstBatch": [{"_id": ObjectId, "name": "Ann"}], "id": int64 0, "ns": "app.users"}, "ok": 1.0}
pub const reply = hex("74000000" ++
    "03 637572736f7200 5b000000" ++
    "04 6669727374426174636800 2c000000" ++
    "03 3000 24000000" ++
    "07 5f696400 56e1fc72e0c917e9c4714161" ++
    "02 6e616d6500 04000000 416e6e00" ++
    "00" ++ // the end of {"_id", "name"}
    "00" ++ // the end of firstBatch
    "12 696400 0000000000000000" ++
    "02 6e7300 0a000000 6170702e757365727300" ++
    "00" ++ // the end of cursor
    "01 6f6b00 000000000000f03f" ++
    "00");

/// Bytes that are not a BSON document, and what they break.
pub const Broken = struct {
    name: []const u8,
    bytes: []const u8,
    /// Whether `RawDocument.init` refuses them already, or only `validate`.
    caught_by: enum { init, validate },
};

pub const broken = [_]Broken{
    .{ .name = "no bytes", .bytes = "", .caught_by = .init },
    .{ .name = "shorter than the smallest document", .bytes = hex("0400 0000"), .caught_by = .init },
    .{ .name = "no terminating 0", .bytes = hex("05000000 01"), .caught_by = .init },
    .{ .name = "length larger than the bytes", .bytes = hex("06000000 00"), .caught_by = .init },
    .{ .name = "length smaller than the bytes", .bytes = hex("05000000 00 00"), .caught_by = .init },
    .{ .name = "negative length", .bytes = hex("ffffffff 00"), .caught_by = .init },
    .{ .name = "unknown type", .bytes = hex("08000000 20 6100 00"), .caught_by = .validate },
    .{ .name = "a 0 before the end", .bytes = hex("07000000 00 00 00"), .caught_by = .validate },
    .{ .name = "key without its 0", .bytes = hex("08000000 0a 6162 00"), .caught_by = .validate },
    .{ .name = "int32 cut short", .bytes = hex("0b000000 10 6100 010000 00"), .caught_by = .validate },
    .{ .name = "double cut short", .bytes = hex("0f000000 01 6100 00000000000000 00"), .caught_by = .validate },
    .{ .name = "ObjectId cut short", .bytes = hex("13000000 07 6100 56e1fc72e0c917e9c47141 00"), .caught_by = .validate },
    .{ .name = "Decimal128 cut short", .bytes = hex("17000000 13 6100 0f000000000000000000000000003e 00"), .caught_by = .validate },
    .{ .name = "string of length 0", .bytes = hex("0d000000 02 6100 00000000 00 00"), .caught_by = .validate },
    .{ .name = "string of negative length", .bytes = hex("0d000000 02 6100 ffffffff 00 00"), .caught_by = .validate },
    .{ .name = "string eats the terminating 0", .bytes = hex("0d000000 02 6100 02000000 00 00"), .caught_by = .validate },
    .{ .name = "string longer than the document", .bytes = hex("10000000 02 6100 ff000000 416e6e00 00"), .caught_by = .validate },
    .{ .name = "string without its 0", .bytes = hex("0e000000 02 6100 02000000 6162 00"), .caught_by = .validate },
    .{ .name = "document shorter than 5 bytes", .bytes = hex("0c000000 03 6100 04000000 00"), .caught_by = .validate },
    .{ .name = "document longer than its parent", .bytes = hex("0d000000 03 6100 06000000 00 00"), .caught_by = .validate },
    .{ .name = "document without its 0", .bytes = hex("0d000000 03 6100 05000000 01 00"), .caught_by = .validate },
    .{ .name = "broken element inside a document", .bytes = hex("10000000 03 6100 08000000 20 6200 00 00"), .caught_by = .validate },
    .{ .name = "broken element inside an array", .bytes = hex("10000000 04 6100 08000000 20 3000 00 00"), .caught_by = .validate },
    .{ .name = "binary of negative length", .bytes = hex("0d000000 05 6100 ffffffff 00 00"), .caught_by = .validate },
    .{ .name = "binary longer than the document", .bytes = hex("10000000 05 6100 04000000 00 010203 00"), .caught_by = .validate },
    .{ .name = "binary without its subtype", .bytes = hex("0c000000 05 6100 00000000 00"), .caught_by = .validate },
    .{ .name = "old binary with a wrong inner length", .bytes = hex("13000000 05 6100 06000000 02 03000000 ffff 00"), .caught_by = .validate },
    .{ .name = "old binary too short for its inner length", .bytes = hex("10000000 05 6100 03000000 02 020000 00"), .caught_by = .validate },
    .{ .name = "boolean 2", .bytes = hex("09000000 08 6100 02 00"), .caught_by = .validate },
    .{ .name = "regular expression without the 0 of its pattern", .bytes = hex("0a000000 0b 6100 5e61 00"), .caught_by = .validate },
    .{ .name = "regular expression without its options", .bytes = hex("0b000000 0b 6100 5e6100 00"), .caught_by = .validate },
    .{ .name = "DBPointer cut short", .bytes = hex("19000000 0c 6100 02000000 6200 56e1fc72e0c917e9c47141 00"), .caught_by = .validate },
    .{ .name = "DBPointer with a broken string", .bytes = hex("1a000000 0c 6100 00000000 6200 56e1fc72e0c917e9c4714161 00"), .caught_by = .validate },
    .{ .name = "JavaScript of length 0", .bytes = hex("0d000000 0d 6100 00000000 00 00"), .caught_by = .validate },
    .{ .name = "symbol without its 0", .bytes = hex("0e000000 0e 6100 02000000 7373 00"), .caught_by = .validate },
    .{ .name = "code with scope shorter than 14 bytes", .bytes = hex("16000000 0f 6100 0d000000 01000000 00 05000000 00 00"), .caught_by = .validate },
    .{ .name = "code with scope longer than its parts", .bytes = hex("1f000000 0f 6100 17000000 02000000 7800 0c000000 10 7800 01000000 00 00 00"), .caught_by = .validate },
    .{ .name = "code with scope shorter than its parts", .bytes = hex("1e000000 0f 6100 15000000 02000000 7800 0c000000 10 7800 01000000 00 00"), .caught_by = .validate },
    .{ .name = "code with scope whose code eats the scope", .bytes = hex("1e000000 0f 6100 16000000 10000000 7800 0c000000 10 7800 01000000 00 00"), .caught_by = .validate },
    .{ .name = "code with scope with a broken scope", .bytes = hex("1e000000 0f 6100 16000000 02000000 7800 0c000000 20 7800 01000000 00 00"), .caught_by = .validate },
    .{ .name = "code with scope longer than the document", .bytes = hex("1e000000 0f 6100 ff000000 02000000 7800 0c000000 10 7800 01000000 00 00"), .caught_by = .validate },
    .{ .name = "second element broken", .bytes = hex("0e000000 0a 6100 10 6200 010000 00"), .caught_by = .validate },
};

/// The bytes that `text` spells in hex; spaces are ignored.
pub fn hex(comptime text: []const u8) *const [hexLen(text)]u8 {
    return comptime &decodeHex(text);
}

fn decodeHex(comptime text: []const u8) [hexLen(text)]u8 {
    // Every call of a table counts against one quota.
    @setEvalBranchQuota(100_000);
    var out: [hexLen(text)]u8 = undefined;
    var n: usize = 0;
    var high: ?u8 = null;
    for (text) |c| {
        if (c == ' ') continue;
        const digit = std.fmt.charToDigit(c, 16) catch @compileError("not a hex digit: " ++ .{c});
        if (high) |h| {
            out[n] = h * 16 + digit;
            n += 1;
            high = null;
        } else high = digit;
    }
    return out;
}

fn hexLen(comptime text: []const u8) usize {
    var digits: usize = 0;
    for (text) |c| {
        if (c != ' ') digits += 1;
    }
    if (digits % 2 != 0) @compileError("an odd number of hex digits: " ++ text);
    return digits / 2;
}
